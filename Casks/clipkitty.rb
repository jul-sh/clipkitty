cask "clipkitty" do
  version "1.0.5"
  sha256 "c182d030b24c23def851d1a89299a53c168d11b1eeab12413aaa3e532a184070"

  url "https://github.com/jul-sh/clipkitty/releases/download/v#{version}/ClipKitty.dmg"
  name "ClipKitty"
  desc "Clipboard history manager with instant fuzzy search"
  homepage "https://github.com/jul-sh/clipkitty"

  app "ClipKitty.app"
end
