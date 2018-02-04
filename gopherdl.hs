import Data.List
import Data.Maybe
import Data.Strings
import Network.Socket
import Control.Exception
import System.FilePath.Posix
import qualified System.Environment as Env
import qualified Network.Socket.ByteString as BsNet
import qualified Data.ByteString.Char8 as C
import System.Console.GetOpt (OptDescr(Option),
                              ArgDescr(NoArg, ReqArg),
                              getOpt,
                              ArgOrder(RequireOrder),
                              usageInfo)

sendAll = BsNet.sendAll
type ByteString = C.ByteString

-- type text \t path \t host \t port \r\n
type MenuLine = (Char, ByteString, ByteString, ByteString, ByteString)
-- host path port
type GopherUrl = (String, String, String)

data Flag = 
      Recursive
    | MaxDepth Int
    | SpanHosts
    | Help
    | Clobber
    | OnlyMenus
    | NoMenus
    | AscendParent
    | Delay Float
    | FlagDebug deriving (Show, Eq)

data GetFileKinds =
    GetAll
  | GetOnlyFiles
  | GetOnlyMenus

data Config = Config
 {  recursive :: Bool
  , maxDepth :: Int
  , spanHosts :: Bool
  , help :: Bool
  , clobber :: Bool
  , onlyMenus :: Bool
  , noMenus :: Bool
  , ascendParent :: Bool
  , delay :: Float
  , flagDebug :: Bool 
  } deriving (Show)

{---------------------}
{------ Helpers ------}
{---------------------}

debugLog :: Show a => Config -> a -> IO a
debugLog conf a =
  (if flagDebug conf
    then putStrLn $ ("DEBUG: " ++ show a)
    else return ()) >> return a

recvAll :: Socket -> IO ByteString
recvAll sock = 
  BsNet.recv sock 4096 >>= recvMore
  where 
    recvMore bytes =
      if (C.length bytes) == 0 
        then return bytes 
        else recvAll sock >>= return . C.append bytes 

appendCRLF :: ByteString -> ByteString
appendCRLF bs = C.append bs $ C.pack "\r\n"

addrInfoHints :: AddrInfo
addrInfoHints = defaultHints { addrSocketType = Stream }

isMenuMenuLine :: MenuLine -> Bool
isMenuMenuLine (t,_,_,_,_) = t == '1'

{--------------------------}
{------ Argv Parsing ------}
{--------------------------}

optionSpec = 
  let argMaxDepth depth = (MaxDepth (read depth::Int)) 
      argDelay delay = (Delay (read delay::Float)) 
  in
  [ Option "r" [] (NoArg Recursive) "Enable recursive downloads"
  , Option "l" [] (ReqArg argMaxDepth "n") "Maximum depth in recursive downloads"
  , Option "s" [] (NoArg SpanHosts) "Span hosts on recursive downloads"
  , Option "h" [] (NoArg Help) "Show this help"
  , Option "c" [] (NoArg Clobber) "Enable file clobbering (overwrite existing)"
  , Option "m" [] (NoArg OnlyMenus) "Only download gopher menus"
  , Option "n" [] (NoArg NoMenus) "Never download gopher menus"
  , Option "p" [] (NoArg AscendParent) "Allow ascension to the parent directories"
  , Option "w" [] (ReqArg argDelay "secs") "Delay between downloads"
  , Option "d" [] (NoArg FlagDebug) "Enable debug messages" ]

isMaxDepth (MaxDepth _) = True
isMaxDepth otherwise = False

isDelay (Delay _) = True
isDelay otherwise = False

findMaxDepth def options =
  case (find isMaxDepth options) of
    Just (MaxDepth d) -> d
    _ -> def

findDelay def options =
  case (find isDelay options) of
    Just (Delay d) -> d
    _ -> def

configFromGetOpt :: ([Flag], [String], [String]) -> ([String], Config)
configFromGetOpt (options, arguments, errors) = 
  ( arguments, 
    Config { recursive = has Recursive
           , maxDepth = findMaxDepth 99 options
           , spanHosts = has SpanHosts
           , help = has Help
           , clobber = has Clobber
           , onlyMenus = has OnlyMenus
           , noMenus = has NoMenus
           , ascendParent = has AscendParent
           , delay = findDelay 0.0 options
           , flagDebug = has FlagDebug })
  where 
    has opt = opt `elem` options 

parseWithGetOpt :: [String] -> ([Flag], [String], [String])
parseWithGetOpt argv = getOpt RequireOrder optionSpec argv

{------------------------}
{----- Menu Parsing -----}
{------------------------}

menuLineToUrl :: MenuLine -> GopherUrl
menuLineToUrl (_, _, path, host, port) =
  (C.unpack host, C.unpack path, C.unpack port)

urlToString :: GopherUrl -> String
urlToString (host, path, port) =
  "gopher://" ++ host ++ ":" ++ port ++ path

validPath :: Maybe MenuLine -> Bool
validPath (Just (_, _, path, _, _)) = 
  (sLen path) /= 0 &&
  not (sStartsWith (strToUpper path) (C.pack "URL:"))

parseMenu :: ByteString -> [MenuLine]
parseMenu rawMenu = 
  map fromJust $ filter valid $ map parseMenuLine lines
  where 
    lines = C.lines rawMenu
    valid line = isJust line && validPath line

parseMenuLine :: ByteString -> Maybe MenuLine
parseMenuLine line = 
  case (strSplitAll "\t" line) of
    [t1, t2, t3, t4] -> Just $ parseToks t1 t2 t3 t4
    _ -> Nothing
  where
    parseToks front path host port =
      ( (strHead front)   -- Type
      , (strDrop 1 front) -- User Text
      , (strTrim path)
      , (strTrim host)
      , (strTrim port) )

{----------------------}
{------ IO & main -----}
{----------------------}

gopherGetRaw :: GopherUrl -> IO ByteString
gopherGetRaw (host, path, port) =
  getAddrInfo (Just addrInfoHints) (Just host) (Just port)
  >>= return . addrAddress . head 
  >>= \addr -> socket AF_INET Stream 0 
    >>= \sock -> connect sock addr
      >> sendAll sock (appendCRLF $ C.pack path)
      >> recvAll sock

sanitizePath path = 
  let nonEmptyString = (/=) 0 . sLen in
  filter nonEmptyString $ strSplitAll "/" path

-- host path port
urlToFilePath :: GopherUrl -> Bool -> FilePath
urlToFilePath (host, path, port) isMenu = 
  joinPath $ 
    [host] ++
    (sanitizePath path) ++
    (if isMenu then ["gophermap"] else [])

main =
  Env.getArgs 
  >>= main' . configFromGetOpt . parseWithGetOpt

save :: ByteString -> GopherUrl -> Bool -> Config -> IO ()
save bs url isMenu conf =
  C.writeFile (urlToFilePath url isMenu) bs

saveFromMenuLine :: ByteString -> MenuLine -> Config -> IO ()
saveFromMenuLine bs ml conf = 
  save bs (menuLineToUrl ml) (isMenuMenuLine ml) conf

gopherGetMenu :: GopherUrl -> IO [MenuLine]
gopherGetMenu url = 
  gopherGetRaw url >>= return . parseMenu

recursiveSave :: [MenuLine] -> GetFileKinds -> Int -> Config -> IO ()
recursiveSave lines getKinds depthLeft conf =
  if (depthLeft == 0) || (lines == [])
    then return ()
    else mapM_ get lines
  where
    {- TODO Use case to come up with filter function for lines -}
    getAll line = return ()
    getFiles line = return ()
    getMenus line = return ()
    get line = 
      case getKinds of
        GetAll -> getAll line
        GetOnlyFiles -> getFiles line
        GetOnlyMenus -> getMenus line
      
      {-
      if (isMenu line) then 
        gopherGetMenu (menuLineToUrl line)
        >>= 
        >>= \ents ->
        saveMenuFromLine gopherGetMenu
      else -}

main' :: ([String], Config) -> IO ()
main' (args, conf) =
  if (help conf) || (length args) == 0 
    then putStr $ usageInfo "gopherdl [options] [urls]" optionSpec
  else if (recursive conf) then
    putStrLn "Recursive!" >>
    gopherGetMenu ("gopher.floodgap.com", "/", "70")
    >>= debugLog conf >> return ()
  else
    gopherGetMenu ("gopher.floodgap.com", "/", "70")
    >>= debugLog conf >> return ()
