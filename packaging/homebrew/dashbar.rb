cask "dashbar" do
  version "0.7.0"
  sha256 "ccf432d5edcea856fff91a41f2b56504f97215a78db699a5096f7867c84c45b1"

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
