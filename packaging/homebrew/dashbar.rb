cask "dashbar" do
  version "0.5.1"
  sha256 "274d2b6602218401a2f9eeb02ae22bc991b52ceef3536ab35df1b806361d9862"

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
