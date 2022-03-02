-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
import Data.Monoid ((<>))
import Options.Applicative
import HA.Services.SSPL.IEM (dumpCSV)


data Commands = DumpIEM IEMOptions

data IEMOptions = IEMOptions { _iemFile :: String }

commands :: Parser Commands
commands = subparser (command "dump-iem" (info iemOptions (progDesc "dump IEM list")))
  where iemOptions = DumpIEM . IEMOptions <$>
          strOption (long "filename"
                      <> short 'f'
                      <> metavar "FILE"
                      <> help "Write IEM to file")

main :: IO ()
main = execParser opts >>= go where
  opts = info (helper <*> commands)
              (fullDesc
              <> progDesc "Print info about current halon build"
              <> header "haloninfo - halon information tool")
  go (DumpIEM (IEMOptions file)) = writeFile file dumpCSV
