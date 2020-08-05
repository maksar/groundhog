{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- | A library for creating datatypes and Groundhog mappings from a database schema. The mappings match the database structure
-- so if you run migration for the generated mappings, no changes to schema should be suggested.
-- The generated Haskell identifiers may sometimes conflict with each other and with Haskell keywords. If that happens, adjust 'ReverseNamingStyle'.
module Database.Groundhog.Inspector
  ( -- * Mapping essentials
    collectTables,
    ReverseNamingStyle (..),
    defaultReverseNamingStyle,
    followReferencedTables,

    -- * Creating Haskell datatypes
    DataCodegenConfig (..),
    defaultDataCodegenConfig,
    generateData,
    showData,
    defaultMkType,
    sqliteMkType,

    -- * Creating mapping settings
    generateMapping,
    minimizeMapping,
    showMappings,
  )
where

import Control.Applicative
import Control.Arrow (left)
import Control.Monad (liftM2, mfilter)
import Data.Aeson.Encode.Pretty
import Data.Bits (finiteBitSize)
import Data.ByteString.Lazy (ByteString)
import Data.Char (isAlphaNum, toLower, toUpper)
import Data.Either (lefts)
import qualified Data.Foldable as Fold
import Data.Function (on)
import Data.Generics
import Data.Int (Int32, Int64)
import Data.List (elemIndex, groupBy, isInfixOf, sort, sortBy)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromJust, fromMaybe, isJust, mapMaybe)
import Data.Monoid ((<>))
import qualified Data.Set as Set
import Data.Time (Day, TimeOfDay, UTCTime)
import Data.Time.LocalTime (ZonedTime)
import qualified Data.Traversable as Traversable
import Database.Groundhog.Core
import Database.Groundhog.Generic (findOne, getDefaultAutoKeyType, haveSameElems)
import Database.Groundhog.Generic.Migration
import Database.Groundhog.TH (NamingStyle, firstChar, mkTHEntityDef)
import Database.Groundhog.TH.Settings
import Language.Haskell.TH
import Text.Regex

-- | Confuguration datatype generation
data DataCodegenConfig = DataCodegenConfig
  { -- | The unique key phantoms can be generated by groundhog-inspector when creating mappings or by groundhog-th when processing mappings.
    -- Set this to False in case you have declaration collisions. They may happen if the mappings are passed to groundhog-th on the fly.
    generateUniqueKeysPhantoms :: Bool,
    -- | Creates a Haskell type. Typically this function analyzes column nullability and its DB type
    mkType :: Column -> Type
  }

defaultDataCodegenConfig :: DataCodegenConfig
defaultDataCodegenConfig =
  DataCodegenConfig
    True
    defaultMkType

-- | It supplies the names for the haskell datatypes
data ReverseNamingStyle = ReverseNamingStyle
  { -- | Create name of the datatype. Parameters: table name.
    mkEntityName :: QualifiedName -> String,
    -- | Create name of the constructor. Parameters: table name.
    mkConstructorName :: QualifiedName -> String,
    -- | Create name of the field. Parameters: table name, column name.
    mkFieldName :: QualifiedName -> String -> String,
    -- | Create name for unique key field. It creates record name both for one-column and composite keys. Parameters: table name, reference.
    mkKeyFieldName :: QualifiedName -> Reference -> String,
    -- | There can be several uniques with the same columns (one primary key and multiple constraints and indexes).
    --  The function must return a stable name regardless of the list order.
    mkChooseReferencedUnique :: QualifiedName -> [UniqueDefInfo] -> UniqueDefInfo,
    -- | Create name for phantom unique key used to parametrise 'Key'. Parameters: table name, unique key definition.
    mkUniqueKeyPhantomName :: QualifiedName -> UniqueDefInfo -> String,
    -- | Create name of unique in mapping. Parameters: table name, unique number, unique key definition.
    mkUniqueName :: QualifiedName -> Int -> UniqueDefInfo -> String
  }

-- | It uses Sqlite type affinity to find the corresponding Haskell type
sqliteMkType :: Column -> Type
sqliteMkType c = typ'
  where
    typ' = if colNull c then ConT ''Maybe `AppT` typ else typ
    typ = case colType c of
      DbOther t -> ConT $ affinityType $ showOther t
      t -> getType t
    affinityType str =
      ( case () of
          _ | contains ["INT"] -> ''Int
          _ | contains ["CHAR", "CLOB", "TEXT"] -> ''String
          _ | contains ["BLOB"] || null str -> ''ByteString
          _ | contains ["REAL", "FLOA", "DOUB"] -> ''Double
          _ -> ''ByteString
      )
      where
        contains = any (`isInfixOf` map toUpper str)

showOther :: OtherTypeDef -> String
showOther (OtherTypeDef ts) = concatMap (either id (error "showOther: OtherTypeDef returned from database analysis contains DbTypePrimitive")) ts

defaultMkType :: Column -> Type
defaultMkType c = typ'
  where
    typ' = if colNull c then ConT ''Maybe `AppT` typ else typ
    typ = getType $ colType c

getType :: DbTypePrimitive -> Type
getType typ = ConT $ getType' typ
  where
    getType' t = case t of
      DbString -> ''String
      DbInt32 -> if intSize == 32 then ''Int else ''Int32
      DbInt64 -> if intSize == 64 then ''Int else ''Int64
      DbReal -> ''Double
      DbBool -> ''Bool
      DbDay -> ''Day
      DbTime -> ''TimeOfDay
      DbDayTime -> ''UTCTime
      DbDayTimeZoned -> ''ZonedTime
      DbBlob -> ''ByteString
      DbOther _ -> ''ByteString
    intSize = finiteBitSize (0 :: Int)

#if !MIN_VERSION_base(4, 7, 0)
  finiteBitSize = bitSize
#endif

defaultReverseNamingStyle :: ReverseNamingStyle
defaultReverseNamingStyle =
  ReverseNamingStyle
    { mkEntityName = \(_, tName) -> firstUpper tName,
      mkConstructorName = \(_, tName) -> firstUpper tName,
      mkFieldName = \(_, tName) col -> firstLower tName ++ firstUpper col,
      mkKeyFieldName = \(_, tName) ref ->
        firstLower tName ++ case map fst $ referencedColumns ref of
          [childCol] -> firstUpper childCol
          refCols -> firstUpper $ concat refCols,
      mkChooseReferencedUnique = \tName uniqs ->
        let uniqs' = sortBy (compare `on` uniqueDefName) uniqs
            isPrimary x = case x of
              UniquePrimary _ -> True
              _ -> False
            -- try primary key, then constraints, then indexes
            filterUnique f = filter (f . uniqueDefType)
            uniq = case filterUnique isPrimary uniqs' ++ filterUnique (== UniqueConstraint) uniqs' ++ filterUnique (== UniqueIndex) uniqs' of
              [] -> error $ "mkChooseReferencedUnique: " ++ show tName ++ " uniques list must be not empty"
              (u : _) -> u
         in uniq,
      mkUniqueKeyPhantomName = \(_, tName) uniq ->
        let -- table cannot reference an expression index
            name' = filter' tName ++ concatMap firstUpper (lefts $ uniqueDefFields uniq)
         in firstUpper $ fromMaybe name' $ uniqueDefName uniq,
      mkUniqueName = \(_, tName) uNum uniq ->
        let name' = filter' tName ++ concatMap firstUpper (lefts $ uniqueDefFields uniq) ++ show uNum
         in fromMaybe name' $ uniqueDefName uniq
    }
  where
    filter' = filter (\c -> isAlphaNum c || c == '_')
    firstLower = firstChar toLower . filter'
    firstUpper = firstChar toUpper . filter'

-- | It looks for the references to the tables not contained in the passed map.
-- If there are such references and the reference filter function returns True, the corresponding TableInfo is fetched and included into the map.
-- The references for the newly added tables are processed in the same way. This function can be useful if your set of tables is created not by 'collectTables'.
followReferencedTables ::
  (PersistBackend m, SchemaAnalyzer (Conn m)) =>
  -- | Decides if we follow reference to this table. It can be used to prevent mapping of the referenced audit or system tables
  (QualifiedName -> Bool) ->
  Map QualifiedName TableInfo ->
  m (Map QualifiedName TableInfo)
followReferencedTables p = go mempty
  where
    getDirectMissingReferences checkedTables currentTables = do
      let getRefs = Set.fromList . map (referencedTableName . snd) . tableReferences
          allReferences = Fold.foldr ((<>) . getRefs) mempty currentTables
          isMissing ref = p ref && ref `Map.notMember` checkedTables && ref `Map.notMember` currentTables
          missingReferences = Set.filter isMissing allReferences
      Fold.foldlM
        ( \acc ref -> do
            x <- analyzeTable ref
            case x of
              Nothing -> fail $ "Reference to " ++ show ref ++ "not found"
              Just x' -> return $ Map.insert ref x' acc
        )
        mempty
        missingReferences
    go checkedTables currentTables | Map.null currentTables = return checkedTables
    go checkedTables currentTables = do
      newTables <- getDirectMissingReferences checkedTables currentTables
      go (checkedTables <> currentTables) newTables

-- | Returns tables from a passed schema and tables which they reference.
-- If you call collectTables several times with different filtering functions,
-- it is better to call 'followReferencedTables' afterwards manually to ensure that no dependencies are missing
--
-- > let filterRefs (schema, tableName) = schema /= "audit"
-- > publicTables  <- collectTables filterRefs (Just "public")
-- > websiteTables <- collectTables filterRefs (Just "website")
-- > let allTables = publicTables <> websiteTables
collectTables ::
  (PersistBackend m, SchemaAnalyzer (Conn m)) =>
  -- | Decides if we follow the reference to a table. It can be used to prevent mapping of the referenced audit or system tables
  (QualifiedName -> Bool) ->
  -- | Schema name
  Maybe String ->
  m (Map QualifiedName TableInfo)
collectTables p schema = do
  sch <- liftM2 (<|>) (pure schema) getCurrentSchema
  tables <- filter p . map (\t -> (sch, t)) <$> listTables sch
  let analyzeTable' ref = do
        x <- analyzeTable ref
        case x of
          Nothing -> error $ "Reference to " ++ show ref ++ "not found"
          Just x' -> return x'
  analyzedTables <- Traversable.mapM analyzeTable' $ Map.fromList $ zip tables tables
  followReferencedTables p analyzedTables

-- | Returns declarations for the mapped datatype and auxiliary declarations like unique key phantom datatypes
generateData ::
  DataCodegenConfig ->
  ReverseNamingStyle ->
  -- | Tables for which the mappings will be generated
  Map QualifiedName TableInfo ->
  Map QualifiedName (Dec, [Dec])
generateData config style tables = Map.mapWithKey (generateData' config style tables) tables

generateData' ::
  DataCodegenConfig ->
  ReverseNamingStyle ->
  Map QualifiedName TableInfo ->
  QualifiedName ->
  TableInfo ->
  (Dec, [Dec])
generateData' DataCodegenConfig {..} ReverseNamingStyle {..} tables tName tInfo = decs
  where
    decs = (dataD' [] (mkName $ mkEntityName tName) [] [constr] [], uniquePhantoms)
    constr = RecC (mkName $ mkConstructorName tName) fields
    -- if a set of columns is referenced, do nothing. If we have a reference to a mapped table, collect all columns and create Key. If reference is to a not mapped table, do nothing
    -- Drop autogenerated id
    idColumns = (filter ((== UniquePrimary True) . uniqueDefType) $ tableUniques tInfo) >>= uniqueDefFields
    -- returns parent name and list of columns for references to mapped datatypes
    getReference c = result
      where
        -- list of references which include this column
        refs = filter ((c `elem`) . map fst . referencedColumns) $ map snd $ tableReferences tInfo
        result = case refs of
          [] -> Nothing
          [ref] -> Just ref
          refs' -> error $ "Column " ++ c ++ " in table " ++ show tName ++ " participates in multiple references: " ++ show refs'
    refUniqueMatch ref u = haveSameElems (==) (map (Left . snd) $ referencedColumns ref) $ uniqueDefFields u
    getReferencedUnique parentName parentInfo ref = mkChooseReferencedUnique parentName uniqs
      where
        uniqs = filter (refUniqueMatch ref) $ tableUniques parentInfo
    isReferenced u = Fold.any getRefs tables
      where
        compareRef ref = referencedTableName ref == tName && refUniqueMatch ref u
        getRefs = any (compareRef . snd) . tableReferences
    uniquePhantoms = if generateUniqueKeysPhantoms then map mkPhantom uniqueKeys else []
      where
        entity = ConT $ mkName $ mkEntityName tName
        mkPhantom u = dataD' [] name [PlainTV v] [c] []
          where
            v = mkName "v"
            name = mkName $ mkUniqueKeyPhantomName tName u
            phantom = ConT ''UniqueMarker `AppT` entity
            c = ForallC [] [equalP' (VarT v) phantom] $ NormalC name []
    uniqueKeys =
      filter isReferenced $
        map (mkChooseReferencedUnique tName) $
          groupBy ((==) `on` sort . uniqueDefFields) uniqueDefs
    uniqueDefs =
      sortBy (compare `on` \u -> (sort $ uniqueDefFields u, uniqueDefType u, uniqueDefName u)) $
        filter ((/= UniquePrimary True) . uniqueDefType) $
          tableUniques tInfo
    fields = go mappedColumns
      where
        mappedColumns = filter ((`notElem` idColumns) . Left . colName) $ tableColumns tInfo
        go [] = []
        go (c : cs) = case getReference $ colName c of
          Just ref ->
            ( case Map.lookup parentName tables of
                Just parentInfo ->
                  (mkName $ mkKeyFieldName tName ref, notStrict', mkKeyType parentInfo)
                Nothing ->
                  (mkName $ mkKeyFieldName tName ref, notStrict', notMappedRefType)
            ) :
            go (filter (`notElem` childCols) cs)
            where
              parentName = referencedTableName ref
              getCols info cols = map (\cName -> findOne "column" colName cName $ tableColumns info) cols
              childCols = getCols tInfo $ map fst $ referencedColumns ref
              notMappedRefType = case childCols of
                [col] -> mkType col
                _ -> foldl AppT (TupleT (length childCols)) $ map mkType childCols
              mkKeyType parentInfo = typ'
                where
                  entity = ConT $ mkName $ mkEntityName parentName
                  uniq = getReferencedUnique parentName parentInfo ref
                  typ =
                    if uniqueDefType uniq == UniquePrimary True
                      then ConT ''AutoKey `AppT` entity
                      else ConT ''Key `AppT` entity `AppT` (ConT ''Unique `AppT` (ConT $ mkName $ mkUniqueKeyPhantomName parentName uniq))
                  typ' = case () of
                    _ | map colNull childCols == map colNull parentCols -> typ
                    _ | map colNull childCols == [True] -> ConT ''Maybe `AppT` typ -- wrap non-composite keys in Maybe
                    _ -> notMappedRefType
                  parentCols = getCols parentInfo $ map snd $ referencedColumns ref
          Nothing -> (mkName $ mkFieldName tName $ colName c, notStrict', mkType c) : go cs

equalP' :: Type -> Type -> Pred
#if MIN_VERSION_template_haskell(2, 10, 0)
equalP' t1 t2 = foldl AppT EqualityT [t1, t2]
#else
equalP' t1 t2 = EqualP t1 t2
#endif

generateMapping :: (PersistBackend m, SchemaAnalyzer (Conn m)) => ReverseNamingStyle -> Map QualifiedName TableInfo -> m (Map QualifiedName PSEntityDef)
generateMapping style tables = do
  m <- getMigrationPack
  return $ generateMappingPure style m tables

generateMappingPure :: DbDescriptor conn => ReverseNamingStyle -> MigrationPack conn -> Map QualifiedName TableInfo -> Map QualifiedName PSEntityDef
generateMappingPure style m tables = Map.mapWithKey (generateMapping' style m tables) tables

generateMapping' :: DbDescriptor conn => ReverseNamingStyle -> MigrationPack conn -> Map QualifiedName TableInfo -> QualifiedName -> TableInfo -> PSEntityDef
generateMapping' ReverseNamingStyle {..} m@MigrationPack {..} tables tName tInfo = entity
  where
    entity = PSEntityDef (mkEntityName tName) (Just $ snd tName) (fst tName) autoKey (Just uniqueKeyDefs) (Just [constr])
    idColumns = (filter ((== UniquePrimary True) . uniqueDefType) $ tableUniques tInfo) >>= uniqueDefFields
    -- returns parent name and list of columns for references to mapped datatypes
    getReference c = result
      where
        -- list of references which include this column
        refs = filter ((c `elem`) . map fst . referencedColumns) $ map snd $ tableReferences tInfo
        result = case refs of
          [] -> Nothing
          [ref] -> Just ref
          refs' -> error $ "Column " ++ c ++ " in table " ++ show tName ++ " participates in multiple references: " ++ show refs'
    (autoKey, autoKeyName) = case idColumns of
      [] -> (Just Nothing, Nothing)
      [Left name] -> (Nothing, Just name)
      _ -> error $ "More than one autoincremented column for " ++ show tName ++ ": " ++ show idColumns
    refUniqueMatch ref u = haveSameElems (==) (map (Left . snd) $ referencedColumns ref) $ uniqueDefFields u
    getReferencedUnique parentName parentInfo ref = mkChooseReferencedUnique parentName uniqs
      where
        uniqs = filter (refUniqueMatch ref) $ tableUniques parentInfo
    isReferenced u = Fold.any getRefs tables
      where
        compareRef ref = referencedTableName ref == tName && refUniqueMatch ref u
        getRefs = any (compareRef . snd) . tableReferences
    uniqueKeyDefs = map mkUniqueKeyDef uniqueKeys
      where
        mkUniqueKeyDef u = PSUniqueKeyDef (mkUniqueName tName (fromJust $ elemIndex u uniqueDefs) u) Nothing Nothing Nothing Nothing Nothing (isDef u)
        -- choose a default unique key if there is no autoincremented key
        defaultUnique = mkChooseReferencedUnique tName uniqueKeys
        isDef u = case autoKey of
          Just Nothing | u == defaultUnique -> Just True
          _ -> Nothing
    -- create keys from uniques only if there are references to them. Autoincremented key is processed separately, so we ignore it.
    uniqueKeys =
      filter isReferenced $
        map (mkChooseReferencedUnique tName) $
          groupBy ((==) `on` sort . uniqueDefFields) uniqueDefs
    uniqueDefs =
      sortBy (compare `on` \u -> (sort $ uniqueDefFields u, uniqueDefType u, uniqueDefName u)) $
        filter ((/= UniquePrimary True) . uniqueDefType) $
          tableUniques tInfo
    uniques = zipWith (\uNum u -> PSUniqueDef (mkUniqueName tName uNum u) (Just $ uniqueDefType u) (map (left $ mkFieldName tName) $ uniqueDefFields u)) [0 ..] uniqueDefs
    constr = PSConstructorDef (mkConstructorName tName) Nothing Nothing autoKeyName (Just fields) (Just uniques)
    fields = go mappedColumns
      where
        mappedColumns = filter ((`notElem` idColumns) . Left . colName) $ tableColumns tInfo
        go [] = []
        go (c : cs) = case getReference $ colName c of
          Just ref ->
            ( case Map.lookup parentName tables of
                Just parentInfo ->
                  let uniq = getReferencedUnique parentName parentInfo ref
                      parentCols = getCols parentInfo $ map snd $ referencedColumns ref
                   in if uniqueDefType uniq == UniquePrimary True
                        then autoKeyRef
                        else -- if nulls don't match, a record will have a tuple or a primitive datatype instead of Key.

                          if map colNull childCols == map colNull parentCols || map colNull childCols == [True]
                            then mappedEmbeddedRef parentCols
                            else if length childCols == 1 then notMappedRef else notMappedEmbeddedRef
                Nothing -> if length childCols == 1 then notMappedRef else notMappedEmbeddedRef
            ) :
            go (filter (`notElem` childCols) cs)
            where
              parentName = referencedTableName ref

              notMappedRef = PSFieldDef (mkKeyFieldName tName ref) (Just $ colName c) (case colType c of DbOther t -> Just $ showOther t; _ -> Nothing) Nothing Nothing (colDefault c) (Just (Just (referencedTableName ref, map snd $ referencedColumns ref), refOnDelete, refOnUpdate)) Nothing
              notMappedEmbeddedRef = PSFieldDef (mkKeyFieldName tName ref) Nothing Nothing Nothing (Just embeddeds) Nothing (Just (Just (referencedTableName ref, map snd $ referencedColumns ref), refOnDelete, refOnUpdate)) Nothing
                where
                  embeddeds = zipWith (\c1 i -> PSFieldDef ("val" ++ show i) (Just $ colName c1) (case colType c1 of DbOther t -> Just $ showOther t; _ -> Nothing) Nothing Nothing (colDefault c1) Nothing Nothing) childCols [0 :: Int ..]
              mappedEmbeddedRef parentCols = PSFieldDef (mkKeyFieldName tName ref) Nothing Nothing Nothing (Just embeddeds) Nothing (Just (Nothing, refOnDelete, refOnUpdate)) Nothing
                where
                  embeddeds = zipWith (\c1 c2 -> PSFieldDef (colName c2) (Just $ colName c1) (showSqlType <$> mfilter (/= colType c2) (Just $ colType c1)) Nothing Nothing (colDefault c1) Nothing Nothing) childCols parentCols
              autoKeyRef = PSFieldDef (mkKeyFieldName tName ref) (Just $ colName c) (showSqlType <$> mfilter (/= autoKeyType) (Just $ colType c)) Nothing Nothing (colDefault c) (Just (Nothing, refOnDelete, refOnUpdate)) Nothing
                where
                  autoKeyType = getDefaultAutoKeyType $ (undefined :: MigrationPack conn -> p conn) m
              refOnDelete = mfilter (/= defaultReferenceOnDelete) $ referenceOnDelete ref
              refOnUpdate = mfilter (/= defaultReferenceOnUpdate) $ referenceOnUpdate ref

              getCols info cols = map (\cName -> findOne "column" colName cName $ tableColumns info) cols
              childCols = getCols tInfo $ map fst $ referencedColumns ref
          Nothing -> PSFieldDef (mkFieldName tName $ colName c) (Just $ colName c) (case colType c of DbOther t -> Just $ showOther t; _ -> Nothing) Nothing Nothing (colDefault c) Nothing Nothing : go cs

subtractSame :: THEntityDef -> PSEntityDef -> PSEntityDef
subtractSame = subtractEntity
  where
    subtractEntity THEntityDef {..} def@PSEntityDef {..} =
      def
        { psDbEntityName = psDbEntityName ?= thDbEntityName,
          psConstructors = fmap (catMaybes . zipWith subtractConstructor thConstructors) psConstructors ?= []
        }
    subtractConstructor THConstructorDef {..} def =
      mfilter notEmpty $
        Just
          def
            { psDbConstrName = psDbConstrName def ?= thDbConstrName,
              psDbAutoKeyName = psDbAutoKeyName def ?=? thDbAutoKeyName,
              psConstrFields = fmap (mapMaybe $ \f -> subtractField (findOne "field" thFieldName (psFieldName f) thConstrFields) f) (psConstrFields def) ?= [],
              psConstrUniques = psConstrUniques def ?= []
            }
      where
        notEmpty PSConstructorDef {..} = isJust psDbConstrName || isJust psDbAutoKeyName || isJust psConstrFields || isJust psConstrUniques
    subtractField THFieldDef {..} def =
      mfilter notEmpty $
        Just
          def
            { psDbFieldName = psDbFieldName def ?= thDbFieldName,
              psDbTypeName = psDbTypeName def ?=? thDbTypeName,
              psDefaultValue = psDefaultValue def ?=? thDefaultValue
            }
      where
        notEmpty PSFieldDef {..} = isJust psDbFieldName || isJust psDbTypeName || isJust psEmbeddedDef || isJust psDefaultValue || isJust psReferenceParent
    a ?= b = mfilter (/= b) a
    a ?=? b = mfilter (const $ a /= b) a

-- | The mappings created by 'generateMapping' contain a lot of setttings. This function makes the settings more compact by eliminating settings
--  which are default for the passed 'NamingStyle'.
minimizeMapping :: NamingStyle -> Dec -> PSEntityDef -> PSEntityDef
minimizeMapping style dec settings = subtractSame (mkTHEntityDef style dec) settings

-- | It pretty-prints Template Haskell declaration into compilable Haskell code
showData :: Dec -> String
showData = removeForalls . pprint . removeModules
  where
    removeForalls s = subRegex (mkRegex "\\bforall\\s*\\.\\s*") s ""
    removeModules = everywhere (mkT $ \name -> mkName $ nameBase name)

-- | It pretty-prints the mapping settings as JSON. Package groundhog-th accepts JSON and YAML which is a more human-readable superset of JSON.
-- You can use a third-party tool to convert JSON to YAML.
showMappings :: [PSEntityDef] -> ByteString
showMappings = encodePretty' config
  where
    config = defConfig {confIndent = Spaces 4, confCompare = keyOrder keys}
    keys = ["entity", "name", "dbName", "schema", "autoKey", "keyDbName", "type", "embeddedType", "columns", "keys", "fields", "uniques"]

dataD' :: Cxt -> Name -> [TyVarBndr] -> [Con] -> [Name] -> InstanceDec

#if MIN_VERSION_template_haskell(2, 12, 0)
dataD' cxt name types constrs derives =
  DataD cxt name types Nothing constrs [DerivClause Nothing (map ConT derives)]
#elif MIN_VERSION_template_haskell(2, 11, 0)
dataD' cxt name types constrs derives =
  DataD cxt name types Nothing constrs (map ConT derives)
#else
dataD' cxt name types constrs derives =
  DataD cxt name types constrs derives
#endif

#if MIN_VERSION_template_haskell(2, 11, 0)
notStrict' :: Bang
notStrict' = Bang NoSourceUnpackedness NoSourceStrictness
#else
notStrict' :: Strict
notStrict' = NotStrict
#endif
