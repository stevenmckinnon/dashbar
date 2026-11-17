cask "dashbar" do
  version "0.10.2"
  sha256 "c825c93e2852ad9b2452d2a89c98826c8db58cc245a7278e89fb18e7378b3f1f"

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
