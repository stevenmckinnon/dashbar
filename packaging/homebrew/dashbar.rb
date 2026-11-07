cask "dashbar" do
  version "0.4.1"
  sha256 "7c44eae4dd719a9d5ca9cd91e94d8f50b555477fe02c1e4c0a2d12a01153afdd"

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
