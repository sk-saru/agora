{- |
Module     : Options
Maintainer : emi@haskell.fyi
Description: Command line options for 'agora-scripts'.

Command line options for 'agora-scripts'.
-}
module Options (Options (..), parseOptions) where

import Options.Applicative ((<**>))
import Options.Applicative qualified as Opt
import qualified Network.Wai.Handler.Warp as Warp

data Options = Options
  { port :: Warp.Port
  }
  deriving stock (Show, Eq)

opt :: Opt.Parser Options
opt =
  Options
    <$> Opt.option Opt.auto
      ( Opt.long "port"
          <> Opt.short 'p'
          <> Opt.metavar "PORT"
          <> Opt.value 3939
          <> Opt.help "The path where the script configuration is."
      )

parseOptions :: IO Options
parseOptions = Opt.execParser p
  where
    p =
      Opt.info
        (opt <**> Opt.helper)
        ( Opt.fullDesc
            <> Opt.progDesc "Generate Agora scripts for off-chain use."
        )
