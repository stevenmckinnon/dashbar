cask "dashbar" do
  version "0.3.1"
  sha256 "47047c3c4e1c736bef19e0f33c6e0c658abc81fd1fe09aa0b554007d08cba23f"

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
