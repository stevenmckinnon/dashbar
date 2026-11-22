cask "dashbar" do
  version "0.12.1"
  sha256 "6de5d40d5f8e763f626e86c2503caaa60cfbd41cf2c5bd1b6da81e54a967af00"

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
