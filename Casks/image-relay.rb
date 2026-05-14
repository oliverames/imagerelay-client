cask "image-relay" do
  version "1.1.2"
  sha256 "7f6af7ca44c4995346813a28f4bcd0ab7908bcfbaf75739ad13bc199a1744da4"

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
