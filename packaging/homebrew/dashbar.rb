cask "dashbar" do
  version "0.5.0"
  sha256 "23e581a56b2af0d8ad3a46917db7462d2ae63f83493637a2fb8840263f8d8a39"

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
