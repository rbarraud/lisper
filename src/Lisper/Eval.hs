{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE PatternSynonyms   #-}

module Lisper.Eval where

import Control.Monad.Except
import Control.Monad.Identity
import Control.Monad.State.Lazy
import Data.List (nub, (\\))

import Lisper.Core
import Lisper.Token
import Lisper.Primitives

type Result a = StateT Env (ExceptT String Identity) a

-- | Evaluate an expression and return the result or error if any.
--
-- The environment maybe updated by specific commands like `set!`, and is
-- handled by the `State` Monad. Env should be mostly left unmodified unless the
-- body is of the form of a `define` or a `set`.
eval :: Scheme -> Result Scheme

-- Evaluating primitive values is no-op:
eval val@(Bool _) = return val
eval val@(List []) = return val
eval val@(Number _) = return val
eval val@(Pair _ _) = return val
eval val@Procedure{} = return val
eval val@(String _) = return val

eval (List [Quote, val]) = return val

-- Variable lookup
eval (Symbol key) = do
    env <- get
    case lookup key env of
        Just val -> return val
        Nothing -> throwError $ "Undefined variable `" ++ key ++ "`"

-- Let special form
-- [TODO] - `let` should be implemented as a macro
eval (List (Let: args : body)) = do
    arguments <- alistToEnv args
    withLocalStateT (arguments ++) $ progn body

-- [TODO] - Verify default value of `cond` if no branches match
-- [TODO] - `cond` should be implemented as a macro
-- Return `NIL if no branches match
eval (List (Cond: body)) =
    case body of
      (List [Symbol "else", value]: _xs) -> eval value
      (List [predicate, value]: xs) ->
          eval predicate >>= \case
              NIL -> eval (List (Cond: xs))
              Bool False -> eval (List (Cond: xs))
              _ -> eval value
      [] -> return NIL
      err -> throwError $ "Syntax error: Expected alist; got " ++ show err ++ " instead"

-- If special form
eval (List [If, predicate, conseq, alt]) =
    eval predicate >>= \case
        Bool False -> eval alt
        _ -> eval conseq

eval (List [If, predicate, conseq]) =
    eval predicate >>= \case
        Bool False -> throwError "Unspecified return value"
        _ -> eval conseq

-- Set special form
--
--`set!` can change any existing binding, but not introduce a new one
eval (List [Set, Symbol var, val]) = do
    void $ eval $ Symbol var
    eval val >>= \result -> modify $ \env -> (var, result) : env
    return NIL

-- [TODO] - `define` supports only the 2 simple forms for now.
-- Define special form, simple case
eval (List [Define, Symbol var, expr]) = do
    result <- eval expr
    modify $ \env -> (var, result) : env
    return result

-- Procedure definitions
eval (List (Define: List (Symbol name : args) : body)) = do
    env <- get
    case duplicates args of
        [] -> do
            put env'
            return fn
          where
            fn = Procedure env' (List args) body
            env' = (name, fn) : env

        x -> throwError $ "Duplicate argument " ++ show x ++ " in function definition"

-- Lambda definition.; (lambda x (car x))
eval (List (Lambda: Symbol arg: body)) = do
    env <- get
    return $ Procedure env (Symbol arg) body

-- Lambda definition.
eval (List (Lambda: List args: body)) = do
    env <- get
    case duplicates args of
      [] -> return $ Procedure env (List args) body
      x -> throwError $ "Duplicate argument " ++ show x ++ " in function definition"

-- Procedure application with name
eval (List (Symbol func : args)) = do
    env <- get
    case lookup func env of
        Just fn -> apply fn args
        Nothing -> apply (Symbol func) args

-- Inline function invocation
eval (List (function : args)) = eval function >>= \fn -> apply fn args

eval lv = throwError $ "Unknown value; " ++ show lv

-- | Apply a function with a list of arguments
--
-- The `alist` is constructed in such a way that all bindings refer to concrete
-- values, rather than other references.
--
-- The alist of the form `((x a))`, rather than `((x 42))` will cause `a` to be
-- looked up in the function closure, rather than the caller's environment. This
-- is prevented by `resolving` the value of each argument to a value other than
-- an atom before zipping with the formal arguments.
--
-- This gives the added benefit that the caller's environment is not needed
-- while evaluating the function body, preventing behavior similar to dynamic
-- scoping.
apply :: Scheme -> [Scheme] -> Result Scheme
apply (Procedure closure (List formal) body) args =
    if arity == applied
    then do
        local <- zipWithM zipper formal args
        withLocalStateT (\env -> closure ++ local ++ env) $ progn body
    else throwError err
  where
   arity = length formal
   applied = length args
   -- [TODO] - Add function name to error report if available
   err = "Expected " ++ show arity ++ " arguments; got " ++ show applied ++ " instead"

-- Handle the case `((lambda x x) 1 2 3)`
apply (Procedure closure (Symbol arg) body) args =
    withLocalStateT (\env -> closure ++ local ++ env) $ progn body
  where
    local = [(arg, List args)]

apply (Symbol func) args =
    case lookup func primitives of
        Just primitive ->
            mapM eval args >>= \args' -> return $ primitive args'
        Nothing ->
            throwError $ "Undefined primitive function " ++ show func

apply fn _args = throwError $ "Procedure Application Error. Fn: " ++ show fn

-- | Evaluate a list of expressions sequentially; and return the result of last
--
-- Progn needs to stop at the first failure and hence the intermediary results
-- are forced with a `seq`. I'm not sure if this is the right way to do things,
-- but works for now.
progn :: [Scheme] -> Result Scheme
progn [] = return NIL
progn [x] = eval x
progn (x:xs) = eval x >>= \lv -> seq lv $ progn xs

-- | Equivalent to `withStateT` in API, but `evalStateT` in behaviour
--
-- Evaluate a state computation with the given initial state and return the
-- final value, discarding the final state.
withLocalStateT :: Monad m => (s -> s) -> StateT s m a -> StateT s m a
withLocalStateT f m =
    get >>= \env -> lift $ fst <$> runStateT m (f env)

-- | Return duplicate items in the list
--
-- >>> duplicates [1, 2, 3, 4, 1]
-- [1]
duplicates :: [Scheme] -> [Scheme]
duplicates xs = xs \\ nub xs

-- | Transforms a let args tuple list to env
--
-- `(let ((a 1) (b (+ 1 1))) (+ a b))` -> `[(a, 1), (b, 2)]`

alistToEnv :: Scheme -> Result Env
alistToEnv (List xs) = mapM trans xs
  where
    -- | Transform an alist of the form `(a (+ 1 1))` to a `(a 1)` expression
    -- [TODO] - trans and zipper look a bit too similar; refactor into one
    trans :: Scheme -> Result (String, Scheme)
    trans (List[Symbol var, val]) = eval val >>= \result -> return (var, result)
    trans _ = throwError "Malformed alist passed to let"

alistToEnv _ = throwError "Second argument to let should be an alist"

-- We are strict! Zipper evaluates arguments before passing to functions
zipper :: Scheme -> Scheme -> Result (String, Scheme)
zipper (Symbol var) val = eval val >>= \result -> return (var, result)
zipper a b = throwError $ "Malformed function arguments" ++ show a  ++ " " ++ show b

-- Exposed API

-- | Evaluate a AST and return result, along with new env
--
-- Evaluation should happen after compilation, which ideally should be enforced
-- with types. This method is stateless and subsequent applications wont behave
-- like a REPL.
evaluate :: [Scheme] -> Either String (Scheme, Env)
evaluate ast = runIdentity $ runExceptT $ runStateT (progn ast) []
