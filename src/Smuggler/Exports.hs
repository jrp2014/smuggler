module Smuggler.Exports where

import Avail (AvailInfo, availNames)
import Debug.Trace (traceM)
import GHC (AnnKeywordId (..), GenLocated (..), IE (..), IEWrappedName (..), Located, Name)
import Language.Haskell.GHC.ExactPrint.Transform (TransformT, addSimpleAnnT, uniqueSrcSpanT)
import Language.Haskell.GHC.ExactPrint.Types (DeltaPos (DP), GhcPs, KeywordId (G), noExt)
import OccName (HasOccName (occName), OccName (occNameFS))
import RdrName (mkVarUnqual)

-- See https://www.machinesung.com/scribbles/terser-import-declarations.html
-- and https://www.machinesung.com/scribbles/ghc-api.html

mkNamesFromAvailInfos :: [AvailInfo] -> [Name]
mkNamesFromAvailInfos = concatMap availNames -- there are also other choices

mkIEVarFromNameT :: Monad m => Name -> TransformT m (Located (IE GhcPs))
mkIEVarFromNameT name = do
  loc <- uniqueSrcSpanT
  return $
    L
      loc
      ( IEVar
          noExt
          (L loc (IEName (L loc (mkVarUnqual ((occNameFS . occName) name)))))
      )

addExportDeclAnnT :: Monad m => Located (IE GhcPs) -> TransformT m ()
addExportDeclAnnT (L _ (IEVar _ (L _ (IEName x)))) =
  addSimpleAnnT x (DP (1, 2)) [(G AnnVal, DP (0, 0))]

addCommaT :: Monad m => Located (IE GhcPs) -> TransformT m ()
addCommaT x = addSimpleAnnT x (DP (0, 0)) [(G AnnComma, DP (0, 0))]

addParensT :: Monad m => Located [Located (IE GhcPs)] -> TransformT m ()
addParensT x =
  addSimpleAnnT
    x
    (DP (0, 1))
    [(G AnnOpenP, DP (0, 0)), (G AnnCloseP, DP (0, 1))]
