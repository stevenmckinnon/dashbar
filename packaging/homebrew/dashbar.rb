cask "dashbar" do
  version "0.11.0"
  sha256 "ee29beb330ba838fe5ade54e501f22b5c8a4c0e867cbb9a5157880d9114647fa"

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
