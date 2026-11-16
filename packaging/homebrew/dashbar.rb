cask "dashbar" do
  version "0.10.0"
  sha256 "a929994c647c9b56fb033043cefb81fc52691ae02f749e63aabce285cda63c5f"

  url "https://github.com/stevenmckinnon/dashbar/releases/download/v#{version}/Dashbar-#{version}.dmg"
  name "Dashbar"
  desc "Menu bar dashboard for AI agent usage, dev servers and system stats"
  homepage "https://usedashbar.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Dashbar.app"
  binary "#{appdir}/Dashbar.app/Contents/Helpers/dashbar"

  zap trash: [
    "~/Library/Application Support/Dashbar",
    "~/Library/Caches/Dashbar",
    "~/Library/Caches/fun.dashbar.app",
    "~/Library/Caches/fun.dashbar.app.sparkle",
    "~/Library/HTTPStorages/fun.dashbar.app",
    "~/Library/Preferences/fun.dashbar.app.plist",
    "~/Library/Saved Application State/fun.dashbar.app.savedState",
  ]
end
