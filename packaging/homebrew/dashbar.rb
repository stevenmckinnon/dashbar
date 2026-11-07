cask "dashbar" do
  version "0.6.0"
  sha256 "cae5e7005af29b7e53e1ec6a71e947069f8a4514567ea468d4d0bed4a942af84"

  url "https://github.com/stevenmckinnon/dashbar/releases/download/v#{version}/Dashbar-#{version}.dmg"
  name "Dashbar"
  desc "Menu bar dashboard for AI agent usage, dev servers and system stats"
  homepage "https://github.com/stevenmckinnon/dashbar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Dashbar.app"

  zap trash: [
    "~/Library/Application Support/Dashbar",
    "~/Library/Preferences/fun.dashbar.app.plist",
  ]
end
