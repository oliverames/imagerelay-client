cask "image-relay" do
  version "1.4.5"
  sha256 "82c1e8287d0438242a9d9128fed0b47965f3b8d475ffe669601ef45fa3adf56b"

  url "https://github.com/oliverames/imagerelay-client/releases/download/v#{version}/ImageRelayClient-#{version}.dmg"
  name "Image Relay"
  desc "Native client for the Image Relay digital asset manager"
  homepage "https://github.com/oliverames/imagerelay-client"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe

  app "Image Relay.app"

  uninstall launchctl: [
              "com.amesconsulting.imagerelay.fileprovider",
              "com.oliverames.imagerelay-client.fileprovider",
            ],
            quit:      [
              "com.amesconsulting.imagerelay",
              "com.oliverames.imagerelay-client",
            ]

  zap trash: [
    "~/Library/Application Support/Image Relay",
    "~/Library/Caches/com.amesconsulting.imagerelay",
    "~/Library/Caches/com.oliverames.imagerelay-client",
    "~/Library/Containers/com.amesconsulting.imagerelay",
    "~/Library/Containers/com.amesconsulting.imagerelay.fileprovider",
    "~/Library/Containers/com.oliverames.imagerelay-client",
    "~/Library/Containers/com.oliverames.imagerelay-client.fileprovider",
    "~/Library/Group Containers/group.com.amesconsulting.imagerelay",
    "~/Library/Group Containers/PV3W52NDZ3.group.com.oliverames.imagerelay-client",
    "~/Library/Preferences/com.amesconsulting.imagerelay.plist",
    "~/Library/Preferences/com.oliverames.imagerelay-client.plist",
  ]
end
