module Main where 

-- system imports
import System.IO         (readFile)
import Control.Exception (catch, IOException)
import System.Exit (die) -- such a morbid name
import Control.Monad (when)
import System.Environment (getArgs)

-- my imports
import qualified SDPLInterpreterOld as Interpreter 
import qualified Parser as Parser 
import qualified SDPLTerms as Terms 
import qualified SyntaxStructure as SS 
import qualified Err as Err
import qualified OperationalStructure as OS

-- parsec
import qualified Text.ParserCombinators.Parsec as Parsec

-- standard containers 
import qualified Data.Map as M




safeLoadFile :: FilePath -> IO (Maybe String)
safeLoadFile p = (Just <$> readFile p) `catch` handler
   where
   handler :: IOException -> IO (Maybe String)
   handler _ = return Nothing

type CanonicalTerm = Terms.Raw Double
type CanonicalProgram = Terms.Prog Double

loadProg :: String -> IO (Maybe CanonicalProgram)
loadProg filename = do 
    x <- safeLoadFile filename
    case x of 
        Nothing -> do 
            putStrLn $ "Filename: " ++ filename ++ " not found"
            return Nothing 
        Just contents -> case Parsec.parse (Parser.parserProg) "" contents of 
            Left e -> do 
                putStrLn $ "Program failed to parse with message: " ++ (show e )
                return Nothing
            Right m -> return $ Just m


evalTermInProg :: CanonicalTerm -> CanonicalProgram -> Err.Err (Terms.ClosedVal Double)
evalTermInProg = Interpreter.fullEvaluationTermInProgStrict "hfree"

repl :: CanonicalProgram -> IO () 
repl prog = do 
    putStrLn "Enter term to evaluate or :q to exit:"
    x <- getLine 
    when (x == ":q") (die "Bye")
    case Parsec.parse (Parser.parserTerm  <* Parsec.eof) "" x of 
        Left e -> do 
            putStrLn $ "Invalid term: " ++ (show e)
            repl prog
        Right term -> case evalTermInProg term prog of 
            Err.Fail msg -> do 
                putStrLn $ "Computation failed because: " ++ msg 
                repl prog 
            Err.Ok val -> do 
                print val 
                repl prog

-- I compile with ghc --make -O2 Main
-- I run with ./Main Examples.sdpl
-- Other options include adding 
-- -ffun-to-thunk
-- -fno-state-hack 
-- -funbox-strict-fields


-- Also, be careful in the interpreter: you have to always type a decimal.  So 1.0 not 1.  
-- Also, I made a choice to make a < b undefined when a == b.  You can change this an recompile.

-- Try rd(x.h(x))(1.001)*(1.001) or rd(x.w(w))(1.001)*1.001 etc
main :: IO ()
main = do 
    args <- getArgs
    case args of 
        [] -> do 
            putStrLn "No program entered, you can still evaluate terms including derivatives.  You can write while-loops, call builtins etc, you just won't have access to functions you wrote.\n"
            putStrLn "Entering read-eval-print-loop.  Enter a term you want to evaluate.  Note this is a simple repl, and there is no history or back.  If you make a mistake just hit enter and type the term again.\n"
            repl M.empty 
        [x] -> do 
            putStrLn $ "Attempting to load program contained in: " ++ x
            prog <- loadProg x
            case prog of 
                Nothing -> putStrLn "At this time your program cannot be run.  Please make necessary changes, or if this is a bug, file a bug report."
                Just realProgram -> repl realProgram
        _ -> putStrLn "At this time, we only support loading a single file."

    

