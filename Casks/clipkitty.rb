cask "clipkitty" do
  version "2.0.0"
  sha256 "70da9f1f3c97361f999b373e00416f8d5c26eca4c624e88c3e22b82efcafac76"

  url "https://github.com/jul-sh/clipkitty/releases/download/v#{version}/ClipKitty.dmg"
  name "ClipKitty"
  desc "Clipboard history manager with instant fuzzy search"
  homepage "https://github.com/jul-sh/clipkitty"

  app "ClipKitty.app"
end
