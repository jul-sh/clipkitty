cask "clipkitty" do
  version "1.0.4"
  sha256 "eb4968b6bb68f192f9594d2b7a11a8ba2d41c06faf3eef93aff84182830f7b83"

  url "https://github.com/jul-sh/clipkitty/releases/download/v#{version}/ClipKitty.dmg"
  name "ClipKitty"
  desc "Clipboard history manager with instant fuzzy search"
  homepage "https://github.com/jul-sh/clipkitty"

  app "ClipKitty.app"
end
