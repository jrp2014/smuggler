{-# LANGUAGE LambdaCase #-}
module Smuggler.Plugin
  ( plugin
  )
where

import Avail (AvailInfo)
import Control.Monad (guard, unless)
import Control.Monad.IO.Class (MonadIO (..))
import Data.List (foldl')
import Debug.Trace (traceM)
import DynFlags (DynFlags, HasDynFlags (getDynFlags))
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import HscTypes (ModSummary (..))
import HsSyn (GhcPs, GhcRn, HsModule (hsmodExports),
              IE (IEThingAbs, IEThingAll, IEThingWith, IEVar), IEWrappedName (IEName),
              ImportDecl (ideclHiding, ideclImplicit, ideclName), LIE, LIEWrappedName)
import IOEnv (readMutVar)
import Language.Haskell.GHC.ExactPrint (Anns, exactPrint)
import Language.Haskell.GHC.ExactPrint.Transform (runTransform, addTrailingCommaT)
import Name (Name, nameSrcSpan)
import Outputable (Outputable (ppr), showSDoc)
import Plugins (CommandLineOption, Plugin (..), PluginRecompile (..), defaultPlugin)
import PrelNames (pRELUDE_NAME)
import RdrName (GlobalRdrElt)
import RnNames (ImportDeclUsage, findImportUsage)
import Smuggler.Anns (removeAnnAtLoc, removeTrailingCommas)
import Smuggler.Exports (addCommaT, addExportDeclAnnT, addParensT, mkIEVarFromNameT,
                         mkNamesFromAvailInfos)
import Smuggler.Parser (runParser)
import SrcLoc (GenLocated (L), Located, SrcSpan (..), srcSpanEndCol, srcSpanStartCol,
               srcSpanStartLine, unLoc)
import System.FilePath ((-<.>))
import TcRnTypes (TcGblEnv (..), TcM)

plugin :: Plugin
plugin = defaultPlugin { typeCheckResultAction = smugglerPlugin
                       , pluginRecompile       = smugglerRecompile
                       }

defaultCol :: Int
defaultCol = 120

-- TODO: would it be worth computing a fingerprint to force recompile if
-- imports were removed?
smugglerRecompile :: [CommandLineOption] -> IO PluginRecompile
smugglerRecompile _ = return NoForceRecompile

smugglerPlugin :: [CommandLineOption] -> ModSummary -> TcGblEnv -> TcM TcGblEnv
smugglerPlugin clis modSummary tcEnv = do
  -- TODO:: Used only for debugging (showSDoc dflags (ppr _ ))
  dflags <- getDynFlags
  let modulePath = ms_hspp_file modSummary
  uses <- readMutVar (tcg_used_gres tcEnv)
  tcEnv <$ liftIO (smuggling dflags uses modulePath)
 where

  addExplicitExports
    :: DynFlags
    -> [AvailInfo]
    -> (Anns, Located (HsModule GhcPs))
    -> (Anns, Located (HsModule GhcPs))
  addExplicitExports dflags exports (anns, L astLoc hsMod) = (anns', ast')
   where
    (ast', (anns', _n), _s) = runTransform anns $ do

      let names = mkNamesFromAvailInfos exports

      exportsList <- mapM mkIEVarFromNameT names
      mapM_ addExportDeclAnnT exportsList
      unless (null exportsList) $ mapM_ addCommaT (init exportsList)

      let lExportsList = L astLoc exportsList
          hsMod'       = hsMod { hsmodExports = Just lExportsList }
      addParensT lExportsList

      return (L astLoc hsMod')

  smuggling :: DynFlags -> [GlobalRdrElt] -> FilePath -> IO ()
  smuggling dflags uses modulePath = do

    -- 0. Read file content as a UTF-8 string (GHC accepts only ASCII or UTF-8)
    -- TODO: Use ms_hspp_buf instead, if we have it?
    setLocaleEncoding utf8
    fileContents <- readFile modulePath

    -- 1. Parse given file
    runParser modulePath fileContents >>= \case
      Left  ()                         -> pure () -- do nothing if file is invalid Haskell
      Right (anns, ast@(L _loc hsMod)) -> do

        -- EXPORTS

        -- What the mdule exports, implicitly or exportsListicitly
        let allExports             = tcg_exports tcEnv
        -- hsmodExports :: Maybe (Located [LIE pass])
        let currentExplicitExports = hsmodExports hsMod

        -- 2.  Annotate with exportsListicit export declaration, if there ism't an existing one
        let (anns', ast') = case currentExplicitExports of
              Just _ -> (anns, ast) -- there is an existing export export list
              Nothing ->
                addExplicitExports dflags allExports (anns, ast)

        putStrLn $ exactPrint ast' anns'

        -- IMPORTS

        -- 3. find positions of unused imports
        let user_imports =
              filter (not . ideclImplicit . unLoc) (tcg_rn_imports tcEnv)
        let usage           = findImportUsage user_imports uses
        let unusedPositions = concatMap unusedLocs usage

        -- 4. Remove positions of unused imports from annotations
        case unusedPositions of
          []     -> pure () -- do nothing if no unused imports
          unused -> do
            let purifiedAnnotations = removeTrailingCommas $ foldl'
                  (\ann (x, y) -> removeAnnAtLoc x y ann)
                  anns'
                  unused
            putStrLn $ exactPrint ast' purifiedAnnotations
            let newContent = exactPrint ast' purifiedAnnotations
            case clis of
              []        -> writeFile modulePath newContent
              (ext : _) -> writeFile (modulePath -<.> ext) newContent

-- TODO: reuse more logic from GHC. Is it possible?
unusedLocs :: ImportDeclUsage -> [(Int, Int)]
unusedLocs (L (UnhelpfulSpan _) _, _, _) = []
unusedLocs (L (RealSrcSpan loc) decl, used, unused)
  |
  -- Do not remove `import M ()`
    Just (False, L _ []) <- ideclHiding decl
  = []
  |
  -- Note [Do not warn about Prelude hiding]
  -- TODO: add ability to support custom prelude
    Just (True, L _ hides) <- ideclHiding decl
  , not (null hides)
  , pRELUDE_NAME == unLoc (ideclName decl)
  = []
  |
  {-
      This is is not always correct, because instances may be imported
      as in first case above

      -- Nothing used; drop entire decl
      | null used = [ (lineNum, colNum)
                    | lineNum <- [srcSpanStartLine loc .. srcSpanEndLine loc]
                    , colNum <-  [srcSpanStartCol loc .. getEndColMax unused]
                    ]
  -}

  -- Everything imported is used; drop nothing
    null unused
  = []
  |
  -- only part of non-hiding import is used
    Just (False, L _ lies) <- ideclHiding decl
  = unusedLies lies
  |
  -- TODO: unused hidings
    otherwise
  = []
 where
  unusedLies :: [LIE GhcRn] -> [(Int, Int)]
  unusedLies = concatMap lieToLoc

  lieToLoc :: LIE GhcRn -> [(Int, Int)]
  lieToLoc (L _ lie) = case lie of
    IEVar      _ name            -> lieNameToLoc name
    IEThingAbs _ name            -> lieNameToLoc name
    IEThingAll _ name            -> lieNameToLoc name
    IEThingWith _ name _ names _ -> concatMap lieNameToLoc (name : names)
    _                            -> []

  lieNameToLoc :: LIEWrappedName Name -> [(Int, Int)]
  lieNameToLoc lieName = do
    L _ (IEName (L (RealSrcSpan lieLoc) name)) <- [lieName]
    guard $ name `elem` unused
    pure (srcSpanStartLine lieLoc, srcSpanStartCol lieLoc)

  getEndColMax :: [Name] -> Int
  getEndColMax u = listMax $ map (findColLoc . nameSrcSpan) u

  findColLoc :: SrcSpan -> Int
  findColLoc (RealSrcSpan   l) = srcSpanEndCol l
  findColLoc (UnhelpfulSpan _) = defaultCol

listMax :: [Int] -> Int
listMax []           = defaultCol
listMax [x         ] = x
listMax (x : y : xs) = listMax ((if x >= y then x else y) : xs)
