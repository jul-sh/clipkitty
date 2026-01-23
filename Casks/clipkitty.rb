cask "clipkitty" do
  version "1.0.0"
  sha256 "908593de7ee5b3793ed5a378c5bec612df1799a265f1eb4dfa413df7fe3015d2"

  url "https://github.com/jul-sh/clipkitty/releases/download/v#{version}/ClipKitty.dmg"
  name "ClipKitty"
  desc "Clipboard history manager with instant fuzzy search"
  homepage "https://github.com/jul-sh/clipkitty"

  app "ClipKitty.app"
end
