{-# LANGUAGE MultiParamTypeClasses, TypeFamilies, FlexibleContexts #-}
{- |

Type classes for PostgreSQL-backed data models.

-}

module Database.PostgreSQL.Models
  ( FromParams(..), Param
  , PostgreSQLModel(..)
  , HasMany(..)
  , TableName(..), fromTableName
  , fromString, IsString
  ) where

import Data.List (intersperse)
import Data.String
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.ToField
import Database.PostgreSQL.Simple.ToRow
import Database.PostgreSQL.Simple.FromField
import Network.Wai.Parse

class FromParams p where
  -- | Converts an HTML form into a type
  fromParams :: [Param] -> Maybe p

instance (FromParams a, FromParams b) => FromParams (a, b) where
  fromParams params = do
    a <- fromParams params
    b <- fromParams params
    return (a, b)

-- | Wrapper type representing PostgreSQL table names
newtype TableName p = TableName String deriving (Show, Eq)

-- | Unwraps a 'TableName'
fromTableName :: TableName p -> String
fromTableName (TableName s) = s

-- | Basis type for PostgreSQL-backed data-models. Instances must, at minimum,
-- implement 'primaryKey', 'tableName' and 'columns'. /Note: the column ordering
-- must match that used in the type's implementation of 'FromRow' and 'ToRow'/
class (FromRow p, ToRow p, ToField (PrimaryKey p), FromField (PrimaryKey p))
  => PostgreSQLModel p where

  type PrimaryKey p :: *

  -- | Given a model, returns the value of it's primary key. In many cases, this
  -- will simply be an alias to a record accessor.
  primaryKey :: p -> Maybe (PrimaryKey p)

  -- | Returns the 'TableName' of the model. Instances should have a top-level value
  -- for the 'TableName' that is always returned. For example:
  --
  -- > employees :: TableName Employee
  -- > employees = TableName "employees"
  -- >
  -- > instance PostgreSQLModel Employee where
  -- >   ...
  -- >   tableName _ = employess
  -- 
  tableName :: p -> TableName p

  -- | Column names excluding primary key. Column order /must/ match the ordering
  -- used in 'ToRow' and 'FromRow'.
  columns :: TableName p -> [String]

  -- | Name of primary key column (default: \"id\").
  primaryKeyName :: TableName p -> String
  primaryKeyName _ = "id"

  -- | Column names with primary-key name prepended.
  columns_ :: TableName p -> [String]
  columns_ tName = (primaryKeyName tName):(columns tName)

  orderBy :: TableName p -> Maybe String
  orderBy _ = Nothing

  -- | Inserts the model into the database. It relies on the primary key
  -- being autogenerated by the database.
  insert :: p -> Connection -> IO (PrimaryKey p)
  insert model conn = do
    query conn template fields >>= return . head . head
    where template = fromString $ concat
            [ "insert into " 
            , fromTableName tName
            , " (" ++ cols ++ ")"
            , " VALUES (" ++ qs ++ ") RETURNING "
            , primaryKeyName tName]
          tName = tableName model
          qs = concat $ intersperse ", " $ map (const "?") $ colNames
          cols = concat $ intersperse ", " $ colNames
          colNameFields = case primaryKey model of
                            Nothing -> (columns tName, toRow model)
                            Just pkey -> ( columns_ tName
                                         , (toField pkey):(toRow model))
          (_, fields) = colNameFields
          (colNames, _) = colNameFields
  
  -- | Create or update the model (uses the primary key to determine if
  -- the model already exists in the database)
  upsert :: p -> Connection -> IO (PrimaryKey p)
  upsert model conn = do
    case primaryKey model of
      Nothing -> insert model conn
      Just pkey -> do
        execute conn template $ toRow model ++ [toField pkey]
        return pkey
    where template = fromString $ concat
            ["update "
            , fromTableName tName
            , " SET "
            , cols, " where ", primaryKeyName tName
            , " = ?"]
          tName = tableName model
          cols = concat $ intersperse ", " $ map (++ " =?") (columns tName)

  -- | Retrieves the single model corresponding to the given primary key
  find :: TableName p -> PrimaryKey p -> Connection -> IO (Maybe p)
  find tn = findFirst tn (primaryKeyName tn)

  -- | Finds the first model in the database based on the column-value contstraint.
  findFirst :: ToField f
            => TableName p
            -> String -- ^ Search column name
            -> f -- ^ Search value
            -> Connection -> IO (Maybe p)
  findFirst tName col val conn = do
    models <- query conn template (Only val)
    case models of
      (model:_) -> return $ Just model
      [] -> return Nothing
    where template = fromString $ concat
            ["select ", cols, " from "
            , fromTableName tName
            , " where "
            , col
            , " = ?"
            , maybe "" (" order by " ++) $ orderBy tName
            , " limit 1"]
          cols = concat $ intersperse ", " $ columns_ tName

  -- | Retrieves all models in the table
  findAll :: TableName p -> Connection -> IO [p]
  findAll tName conn = query_ conn template
    where template = fromString $ concat 
            [ "select ", cols, " from "
            , fromTableName tName
            , maybe "" (" order by " ++) $ orderBy tName]
          cols = concat $ intersperse ", " $ columns_ tName

  -- | Retrieves all models in the table subject to the column-value constraint.
  findAllBy :: ToField f
            => TableName p
            -> String -- ^ Search column name
            -> f -- ^ Search value
            -> Connection -> IO [p]
  findAllBy tName col val conn = query conn template (Only val)
    where template = fromString $ concat 
            [ "select ", cols, " from "
            , fromTableName tName
            , " where ", col, " = ?"
            , maybe "" (" order by " ++) $ orderBy tName]
          cols = concat $ intersperse ", " $ columns_ tName

-- | Defines a \"has-many\" relationship between two models, where the 'parent'
-- model may be associated with zero or more of the 'child' model. Specifically,
-- the 'child' table has a foreign key column pointing to the parent model.
class (PostgreSQLModel parent, PostgreSQLModel child) =>
  HasMany parent child where
  
  foreignKey :: TableName parent -> TableName child -> String
  foreignKey tName _ = fromTableName tName ++ "_" ++ (primaryKeyName tName)

  childrenOf :: parent -> TableName child -> Connection -> IO [child]
  childrenOf parent ctName conn = query conn template (Only $ primaryKey parent)
    where template = fromString $ concat $
            [ "select ", childColumns, " from "
            , fromTableName ctName
            , " where "
            , foreignKey ptName ctName
            , " = ?"
            , maybe "" (" order by " ++) $ orderBy ctName]
          ptName = tableName parent
          childColumns = concat $ intersperse ", " $ columns_ ctName

  childOf :: parent -> TableName child
          -> PrimaryKey child -> Connection -> IO (Maybe child)
  childOf parent ctName v = childOfBy parent ctName (primaryKeyName ctName) v

  childOfBy :: ToField v
          => parent
          -> TableName child
          -> String
          -> v
          -> Connection -> IO (Maybe child)
  childOfBy parent ctName col pkeyc conn = do
    mchildren <- query conn template (primaryKey parent, pkeyc) 
    case mchildren of
      [] -> return Nothing
      (c:_) -> return $ Just c
    where template = fromString $ concat $
            [ "select ", childColumns, " from "
            , fromTableName ctName
            , " where "
            , foreignKey ptName ctName, " = ?"
            , " and ", col, " = ?"
            , maybe "" (" order by " ++) $ orderBy ctName
            , " limit 1"]
          ptName = tableName parent
          childColumns = concat $ intersperse ", " $ columns_ ctName

  childrenOfBy :: ToField f
             => parent
             -> TableName child
             -> String
             -> f
             -> Connection -> IO [child]
  childrenOfBy parent ctName col val conn =
    query conn template (primaryKey parent, val)
    where template = fromString $ concat $
            [ "select ", childColumns, " from "
            , fromTableName ctName
            , " where "
            , foreignKey ptName ctName
            , " = ? and ", col, " = ?"
            , maybe "" (" order by " ++) $ orderBy ctName]
          ptName = tableName parent
          childColumns = concat $ intersperse ", " $ columns_ ctName

  insertFor :: parent -> child -> Connection -> IO (PrimaryKey child)
  insertFor parent chld conn = do
    query conn template (fields ++ [toField $ primaryKey parent])
      >>= return . head . head
    where template = fromString $ concat
            [ "insert into " 
            , fromTableName ctName
            , " (", cols, ", ", foreignKey ptName ctName, ")"
            , " VALUES (", qs, ", ?) "
            , " RETURNING "
            , primaryKeyName ctName]
          ctName = tableName chld
          ptName = tableName parent
          qs = concat $ intersperse ", " $ map (const "?") $ colNames
          cols = concat $ intersperse ", " $ colNames
          colNameFields = case primaryKey chld of
                            Nothing -> (columns ctName, toRow chld)
                            Just pkey -> ( columns_ ctName
                                         , (toField pkey):(toRow chld))
          (_, fields) = colNameFields
          (colNames, _) = colNameFields

