cask "image-relay" do
  version "1.3.1"
  sha256 "915bab9e95032c06beb1aacbdfb63a56bdd1fae9da5ce8a637a1ba10d2e4bcf5"

  url "https://github.com/oliverames/imagerelay-client/releases/download/v#{version}/ImageRelayClient-#{version}.dmg",
      verified: "github.com/oliverames/imagerelay-client/"
  name "Image Relay"
  desc "Native macOS client for the Image Relay digital asset manager"
  homepage "https://github.com/oliverames/imagerelay-client"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Image Relay.app"

  uninstall quit:      "com.oliverames.imagerelay-client",
            launchctl: "com.oliverames.imagerelay-client.fileprovider"

  zap trash: [
    "~/Library/Application Support/Image Relay",
    "~/Library/Caches/com.oliverames.imagerelay-client",
    "~/Library/Containers/com.oliverames.imagerelay-client",
    "~/Library/Containers/com.oliverames.imagerelay-client.fileprovider",
    "~/Library/Group Containers/PV3W52NDZ3.group.com.oliverames.imagerelay-client",
    "~/Library/Preferences/com.oliverames.imagerelay-client.plist",
  ]
end
