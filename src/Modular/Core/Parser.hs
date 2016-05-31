{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Modular.Core.Parser where

import Control.Applicative ((<$>),(<*>),(*>),(<*))
import Control.Monad.Reader
import Data.List (foldl')
import Text.Parsec
import qualified Text.Parsec.Token as Token

import Utils.ABT
import Utils.Names
import Utils.Plicity
import Utils.Vars
import Modular.Core.ConSig
import Modular.Core.DeclArg
import Modular.Core.Term
import Modular.Core.Program




-- Language Definition

languageDef :: Token.LanguageDef st
languageDef = Token.LanguageDef
              { Token.commentStart = "{-"
              , Token.commentEnd = "-}"
              , Token.commentLine = "--"
              , Token.nestedComments = True
              , Token.identStart = letter <|> char '_'
              , Token.identLetter = alphaNum <|> char '_' <|> char '\''
              , Token.opStart = oneOf ""
              , Token.opLetter = oneOf ""
              , Token.reservedNames = ["data","case","motive","of","end"
                                      ,"where","let","Type","module","open"
                                      ,"opening","as","using","hiding"
                                      ,"renaming","to"
                                      ]
              , Token.reservedOpNames = ["|","||","->","\\",":","::","=","."]
              , Token.caseSensitive = True
              }

tokenParser = Token.makeTokenParser languageDef

identifier = Token.identifier tokenParser
reserved = Token.reserved tokenParser
reservedOp = Token.reservedOp tokenParser
parens = Token.parens tokenParser
braces = Token.braces tokenParser
symbol = Token.symbol tokenParser
whiteSpace = Token.whiteSpace tokenParser





-- names

varName = do lookAhead (lower <|> char '_')
             identifier

decName = do lookAhead upper
             identifier




-- term parsers

variable = do x <- varName
              guard (x /= "_")
              return $ Var (Free (FreeVar x))

dottedName = try $ do
               modName <- decName
               _ <- reservedOp "."
               valName <- varName
               return $ In (Defined (DottedLocal modName valName))

annotation = do m <- try $ do
                  m <- annLeft
                  _ <- reservedOp ":"
                  return m
                t <- annRight
                return $ annH m t

typeType = do _ <- reserved "Type"
              return $ In Type

explFunType = do (xs,arg) <- try $ do
                   (xs,arg) <- parens $ do
                     xs <- many1 varName
                     _ <- reservedOp ":"
                     arg <- term
                     return (xs,arg)
                   _ <- reservedOp "->"
                   return (xs,arg)
                 ret <- funRet
                 let xsFreshDummies =
                       map unBNSString
                           (dummiesToFreshNames
                              (freeVarNames ret)
                              (map BNSString xs))
                 return $ helperFold (\x -> funH Expl x arg)
                                     xsFreshDummies
                                     ret

implFunType = do (xs,arg) <- try $ do
                   (xs,arg) <- braces $ do
                     xs <- many1 varName
                     _ <- reservedOp ":"
                     arg <- term
                     return (xs,arg)
                   _ <- reservedOp "->"
                   return (xs,arg)
                 ret <- funRet
                 let xsFreshDummies =
                       map unBNSString
                           (dummiesToFreshNames
                              (freeVarNames ret)
                              (map BNSString xs))
                 return $ helperFold (\x -> funH Impl x arg)
                                     xsFreshDummies
                                     ret

binderFunType = explFunType <|> implFunType

noBinderFunType = do arg <- try $ do
                       arg <- funArg
                       _ <- reservedOp "->"
                       return arg
                     ret <- funRet
                     let xsFreshDummies =
                           unBNSString
                             (dummiesToFreshNames
                                (freeVarNames ret)
                                (BNSString "_"))
                     return $ funH Expl xsFreshDummies arg ret

funType = binderFunType <|> noBinderFunType

explArg = do x <- varName
             return (Expl,x)

implArg = do x <- braces varName
             return (Impl,x)

lambdaArg = explArg <|> implArg

lambda = do xs <- try $ do
              _ <- reservedOp "\\"
              many1 lambdaArg
            _ <- reservedOp "->"
            b <- lamBody
            let xsFreshDummies =
                  map (\(plic,s) -> (plic, unBNSString s))
                      (dummiesToFreshNames
                         (freeVarNames b)
                         (map (\(plic,s) -> (plic, BNSString s)) xs))
            return $ helperFold (\(plic,x) -> lamH plic x)
                                xsFreshDummies
                                b

application = do (f,pa) <- try $ do
                   f <- appFun
                   pa <- appArg
                   return (f,pa)
                 pas <- many appArg
                 return $ foldl' (\f' (plic,a') -> appH plic f' a') f (pa:pas)

bareCon = do conName <- decName
             return $ BareLocal conName

dottedCon = try $ do
              modName <- decName
              _ <- reservedOp "."
              conName <- decName
              return $ DottedLocal modName conName

constructor = dottedCon <|> bareCon

noArgConData = do c <- constructor
                  return $ conH c []

conData = do c <- constructor
             as <- many conArg
             return $ conH c as

assertionPattern = do _ <- reservedOp "."
                      m <- assertionPatternArg
                      return $ assertionPatH m

varPattern = do x <- varName
                return $ Var (Free (FreeVar x))

noArgConPattern = do c <- constructor
                     return $ conPatH c []

conPattern = do c <- constructor
                ps <- many conPatternArg
                return $ conPatH c ps

parenPattern = parens pattern

pattern = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

consMotivePart = do (xs,a) <- try $ parens $ do
                      xs <- many1 varName
                      _ <- reservedOp ":"
                      a <- term
                      return (xs,a)
                    _ <- reservedOp "||"
                    (xs',as,b) <- caseMotiveParts
                    return (xs ++ xs', replicate (length xs) a ++ as, b)

nilMotivePart = do b <- term
                   return ([], [], b)

caseMotiveParts = consMotivePart <|> nilMotivePart

caseMotive = do (xs,as,b) <- caseMotiveParts
                let xsFreshDummies =
                      map unBNSString
                          (dummiesToFreshNames
                             (freeVarNames b ++ (freeVarNames =<< as))
                             (map BNSString xs))
                return $ caseMotiveH xsFreshDummies as b

clause = do ps <- try $ do
              ps <- pattern `sepBy` reservedOp "||"
              _ <- reservedOp "->"
              return ps
            b <- term
            let freshenedPs =
                  dummiesToFreshNames (freeVarNames b) ps
                xs = freeVarNames =<< freshenedPs
            return $ clauseH xs freshenedPs b

caseExp = do _ <- reserved "case"
             ms <- caseArg `sepBy1` reservedOp "||"
             _ <- reservedOp "motive"
             mot <- caseMotive
             _ <- reserved "of"
             _ <- optional (reservedOp "|")
             cs <- clause `sepBy` reservedOp "|"
             _ <- reserved "end"
             return $ caseH ms mot cs

parenTerm = parens term

term = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedName <|> conData <|> caseExp <|> variable <|> typeType




annLeft = application <|> parenTerm <|> dottedName <|> conData <|> variable <|> typeType

annRight = funType <|> application <|> parenTerm <|> lambda <|> dottedName <|> conData <|> caseExp <|> variable <|> typeType

funArg = application <|> parenTerm <|> dottedName <|> conData <|> caseExp <|> variable <|> typeType

funRet = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedName <|> conData <|> caseExp <|> variable <|> typeType

lamBody = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedName <|> conData <|> caseExp <|> variable <|> typeType

appFun = parenTerm <|> variable <|> dottedName <|> typeType

rawExplAppArg = parenTerm <|> dottedName <|> noArgConData <|> variable <|> typeType

explAppArg = do m <- rawExplAppArg
                return (Expl,m)

rawImplAppArg = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedName <|> conData <|> caseExp <|> variable <|> typeType

implAppArg = do m <- braces $ rawImplAppArg
                return (Impl,m)

appArg = explAppArg <|> implAppArg

rawExplConArg = parenTerm <|> dottedName <|> noArgConData <|> variable <|> typeType

explConArg = do m <- rawExplConArg
                return (Expl,m)

rawImplConArg = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedName <|> conData <|> caseExp <|> variable <|> typeType

implConArg = do m <- braces $ rawImplConArg
                return (Impl,m)

conArg = explConArg <|> implConArg

caseArg = annotation <|> funType <|> application <|> parenTerm <|> lambda <|> dottedName <|> conData <|> variable <|> typeType

rawExplConPatternArg = assertionPattern <|> parenPattern <|> noArgConPattern <|> varPattern

explConPatternArg = do p <- rawExplConPatternArg
                       return (Expl,p)

rawImplConPatternArg = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

implConPatternArg = do p <- braces $ rawImplConPatternArg
                       return (Impl,p)

conPatternArg = explConPatternArg <|> implConPatternArg

assertionPatternArg = parenTerm <|> noArgConData <|> variable <|> typeType





parseTerm str = case parse (whiteSpace *> term <* eof) "(unknown)" str of
                  Left e -> Left (show e)
                  Right p -> Right p






-- statement parsers

eqTermDecl = do (x,t) <- try $ do
                  _ <- reserved "let"
                  x <- varName
                  _ <- reservedOp ":"
                  t <- term
                  _ <- reservedOp "="
                  return (x,t)
                m <- term
                _ <- reserved "end"
                return $ TermDeclaration x t m

whereTermDecl = do (x,t) <- try $ do
                     _ <- reserved "let"
                     x <- varName
                     _ <- reservedOp ":"
                     t <- term
                     _ <- reserved "where"
                     return (x,t)
                   _ <- optional (reservedOp "|")
                   preclauses <- patternMatchClause x `sepBy1` reservedOp "|"
                   _ <- reserved "end"
                   return $ WhereDeclaration x t preclauses
    
    

patternMatchClause x = do _ <- symbol x
                          ps <- many wherePattern
                          _ <- reservedOp "="
                          b <- term
                          let freshenedPs =
                                dummiesToFreshNames (freeVarNames b) ps
                              xs = do (_,p) <- freshenedPs
                                      freeVarNames p
                          return ( map fst freshenedPs
                                 , (xs, map snd freshenedPs, b)
                                 )

rawExplWherePattern = assertionPattern <|> parenPattern <|> noArgConPattern <|> varPattern

explWherePattern = do p <- rawExplWherePattern
                      return (Expl,p)

rawImplWherePattern = assertionPattern <|> parenPattern <|> conPattern <|> varPattern

implWherePattern = do p <- braces $ rawImplWherePattern
                      return (Impl,p)

wherePattern = implWherePattern <|> explWherePattern

termDecl = eqTermDecl <|> whereTermDecl

alternative = do c <- decName
                 as <- alternativeArgs
                 _ <- reservedOp ":"
                 t <- term
                 return (c,conSigH as t)

explAlternativeArg = parens $ do
                       xs <- many1 varName
                       _ <- reservedOp ":"
                       t <- term
                       return $ [ DeclArg Expl x t | x <- xs ]

implAlternativeArg = braces $ do
                       xs <- many1 varName
                       _ <- reservedOp ":"
                       t <- term
                       return $ [ DeclArg Impl x t | x <- xs ]

alternativeArg = explAlternativeArg <|> implAlternativeArg

alternativeArgs = do argss <- many alternativeArg
                     return (concat argss)

emptyTypeDecl = do (tycon,tyargs) <- try $ do
                     _ <- reserved "data"
                     tycon <- decName
                     tyargs <- typeArgs
                     _ <- reserved "end"
                     return (tycon,tyargs)
                   return $ TypeDeclaration tycon tyargs []

nonEmptyTypeDecl = do (tycon,tyargs) <- try $ do
                        _ <- reserved "data"
                        tycon <- decName
                        tyargs <- typeArgs
                        _ <- reserved "where"
                        return (tycon,tyargs)
                      _ <- optional (reservedOp "|")
                      alts <- alternative `sepBy` reservedOp "|"
                      _ <- reserved "end"
                      return $ TypeDeclaration tycon tyargs alts

explTypeArg = parens $ do
                xs <- many1 varName
                _ <- reservedOp ":"
                t <- term
                return $ [ DeclArg Expl x t | x <- xs ]

implTypeArg = braces $ do
                xs <- many1 varName
                _ <- reservedOp ":"
                t <- term
                return $ [ DeclArg Impl x t | x <- xs ]

typeArg = explTypeArg <|> implTypeArg

typeArgs = do argss <- many typeArg
              return (concat argss)

typeDecl = emptyTypeDecl <|> nonEmptyTypeDecl

statement = TmDecl <$> termDecl
        <|> TyDecl <$> typeDecl





-- open settings

oAs = optionMaybe $ do
        _ <- reserved "as"
        decName

oHidingUsing = optionMaybe (hiding <|> using)
  where
    hiding = do _ <- reserved "hiding"
                ns <- parens (sepBy (varName <|> decName) (reservedOp ","))
                return (Hiding ns)
    using = do _ <- reserved "using"
               ns <- parens (sepBy (varName <|> decName) (reservedOp ","))
               return (Using ns)

oRenaming = do m <- openRenamingP
               case m of
                 Nothing -> return []
                 Just ns -> return ns
  where
    openRenamingP = optionMaybe $ do
                      _ <- reserved "renaming"
                      parens (sepBy (varRen <|> decRen) (reservedOp ","))
    varRen = do n <- varName
                _ <- reserved "to"
                n' <- varName
                return (n,n')
    decRen = do n <- decName
                _ <- reserved "to"
                n' <- decName
                return (n,n')

openSettings = OpenSettings <$> decName
                            <*> oAs
                            <*> oHidingUsing
                            <*> oRenaming




-- modules

modulOpen = do n <- try $ do
                 _ <- reserved "module"
                 n <- decName
                 _ <- reserved "opening"
                 return n
               _ <- optional (reserved "|")
               settings <- sepBy openSettings (reserved "|")
               _ <- reserved "where"
               stmts <- many statement
               _ <- reserved "end"
               return $ Module n settings stmts

modulNoOpen = do n <- try $ do
                   _ <- reserved "module"
                   n <- decName
                   _ <- reserved "where"
                   return n
                 stmts <- many statement
                 _ <- reserved "end"
                 return $ Module n [] stmts

modul = modulOpen <|> modulNoOpen





-- programs

program = Program <$> many modul



parseProgram :: String -> Either String Program
parseProgram str
  = case parse (whiteSpace *> program <* eof) "(unknown)" str of
      Left e -> Left (show e)
      Right p -> Right p