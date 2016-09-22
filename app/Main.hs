{- integrate
Gregory W. Schwartz

Integrate data from multiple sources to find consistent (or inconsistent)
entities.
-}

{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

-- Standard
import Data.Bool
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import Data.Monoid
import System.IO
import Control.Monad

-- Cabal
import qualified Data.Vector as V
import qualified Data.ByteString.Lazy.Char8 as CL
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Csv as CSV
import qualified Control.Lens as L
import Options.Generic

-- Local
import Types
import Utility
import Load
import Edge.Correlation
import Edge.Aracne
import Alignment.RandomWalk
import Integrate
import Print

-- | Command line arguments
data Options = Options { dataInput       :: Maybe String
                                        <?> "(FILE) The input file containing the data intensities. Follows the format: dataLevel,dataReplicate,vertex,intensity. dataLevel is the level (the base level for the experiment, like \"proteomic_Myla\" or \"RNA_MyLa\" for instance), dataReplicate is the replicate in that experiment that the entity is from (the name of that data set with the replicate name, like \"RNA_MyLa_1\"), and vertex is the name of the entity (must match those in the vertex-input), and the intensity is the value of this entity in this data set."
                       , vertexInput     :: Maybe String
                                        <?> "(FILE) The input file containing similarities between entities. Follows the format: vertexLevel1,vertexLevel2, vertex1,vertex2,similarity. vertexLevel1 is the level (the base title for the experiment, \"data set\") that vertex1 is from, vertexLevel2 is the level that vertex2 is from, and the similarity is a number representing the similarity between those two entities. If not specified, then the same entity (determined by vertex in data-input) will have a similarity of 1, different entities will have a similarity of 0."
                       , entityDiff      :: Maybe T.Text
                                        <?> "When comparing entities that are the same, ignore the text after this separator. Used for comparing phosphorylated positions with another level. For example, if we have a strings ARG29 and ARG29_7 that we want to compare, we want to say that their value is the highest in correlation, so this string would be \"_\""
                       , alignmentMethod :: Maybe String
                                        <?> "([CosineSimilarity] | RandomWalker) The method to get integrated vertex similarity between levels. CosineSimilarity uses the cosine similarity of each  vertex in each network compared to the other vertices in  other networks. RandomWalker uses a random walker based  network alignment algorithm in order to get similarity."
                       , edgeMethod      :: Maybe String
                                        <?> "([ARACNE BANDWIDTH] | KendallCorrelation) The method to use for the edges between entities in the coexpression matrix. The default bandwith for ARACNE is 0.1."
                       , walkerRestart   :: Maybe Double
                                        <?> "([0.05] | PROBABILITY) For the random walker algorithm, the probability of making  a jump to a random vertex. Recommended to be the ratio of  the total number of vertices in the top 99% smallest  subnetworks to the total number of nodes in the reduced  product graph (Jeong, 2015)."
                       , steps           :: Maybe Int
                                        <?> "([10000] | STEPS) For the random walker algorithm, the number of steps to take  before stopping."
                       , premade         :: Bool
                                        <?> "Whether the input data (dataInput) is a pre-made network of the format \"[([\"VERTEX\"], [(\"SOURCE\", \"DESTINATION\", WEIGHT)])]\", where VERTEX, SOURCE, and DESTINATION are of type INT starting at 0, in order, and WEIGHT is a DOUBLE representing the weight of the edge between SOURCE and DESTINATION."
                       , test            :: Maybe String
                                        <?> "The filename of the permuted vertices for accuracy testing purposes. If supplied, the output is changed to an accuracy measure. In this case, we get the total rank below the number of permuted vertices divided by the theoretical maximum (so if there were five changed vertices out off 10 and two were rank 8 and 10 while the others were in the top five, we would have (1 - ((3 + 5) / (10 + 9 + 8 + 7 + 6))) as the accuracy."
                       }
               deriving (Generic)

instance ParseRecord Options

-- | Get all of the required information for integration.
getIntegrationInput :: Options -> IO (IDMap, IDVec, VertexSimMap, EdgeSimMap)
getIntegrationInput opts = do
    let processCsv = snd . either error id

    dataEntries   <- fmap (processCsv . CSV.decodeByName)
                   . maybe CL.getContents CL.readFile
                   . unHelpful
                   . dataInput
                   $ opts

    let levels       =
            entitiesToLevels . datasToEntities . V.toList $ dataEntries
        unifiedData  = unifyAllLevels . fmap snd $ levels
        levelNames   = Set.toList . Set.fromList . fmap fst $ levels
        idMap        = getIDMap unifiedData
        idVec        = getIDVec unifiedData
        eDiff        = fmap EntityDiff . unHelpful . entityDiff $ opts

    let vertexContents =
            fmap (fmap (processCsv . CSV.decodeByName) . CL.readFile)
                . unHelpful
                . vertexInput
                $ opts
    vertexSimMap <- maybe
                        (return . defVertexSimMap idMap $ levelNames)
                        (fmap (vertexCsvToLevels idMap . V.toList))
                        vertexContents

    let edgeSimMethod = maybe (ARACNE 0.1) read . unHelpful . edgeMethod $ opts
        edgeSimMap    = EdgeSimMap
                      . Map.fromList
                      . fmap ( L.over L._2 ( getSimMat edgeSimMethod
                                           . standardizeLevel idMap
                                           )
                             )
                      $ levels
        getSimMat (ARACNE h)         = getSimMatAracne
                                        (Bandwidth h)
                                        eDiff
                                        idMap
        getSimMat KendallCorrelation = getSimMatKendall
                                        (Default 0)
                                        eDiff
                                        (MaximumEdge 1)
                                        idMap

    return (idMap, idVec, vertexSimMap, edgeSimMap)

-- | Get all of the network info that is pre-made for input into the integration method.
getPremadeIntegrationInput :: Options -> IO (IDMap, IDVec, VertexSimMap, EdgeSimMap)
getPremadeIntegrationInput opts = do

    contents <- maybe getContents readFile
              . unHelpful
              . dataInput
              $ opts

    return . getPremadeNetworks $ (read contents :: [([String], [(String, String, Double)])])

-- | Show the accuracy of a test analysis.
showAccuracy :: String -> IDVec -> NodeCorrScores -> IO T.Text
showAccuracy file idVec nodeCorrScores = do
    truthContents <- readFile file

    let truthSet = Set.fromList
                 . fmap (ID . T.pack)
                 $ (\x -> read x :: [String]) truthContents

    return . T.pack . show . getAccuracy truthSet idVec $ nodeCorrScores

main :: IO ()
main = do
    opts <- getRecord "integrate, Gregory W. Schwartz\
                      \ Integrate data from multiple sources to find consistent\
                      \ (or inconsistent) entities."

    (idMap, idVec, vertexSimMap, edgeSimMap) <- bool
                                                    (getIntegrationInput opts)
                                                    (getPremadeIntegrationInput opts)
                                              . unHelpful
                                              . premade
                                              $ opts

    nodeCorrScores <- integrate
                        ( maybe CosineSimilarity read
                        . unHelpful
                        . alignmentMethod
                        $ opts
                        )
                        vertexSimMap
                        edgeSimMap
                        ( WalkerRestart
                        . fromMaybe 0.05
                        . unHelpful
                        . walkerRestart
                        $ opts
                        )
                        (Counter . fromMaybe 10000 . unHelpful . steps $ opts)

    case unHelpful . test $ opts of
        Nothing  -> T.putStr . printNodeCorrScores idVec $ nodeCorrScores
        (Just x) -> T.putStr =<< (showAccuracy x idVec $ nodeCorrScores)

    return ()
