cask "betterwm" do
  version "0.11.19"
  sha256 "c805ca6c202b55d50a9ebf047406a0552d3900744fa13ffaf0026741925fc6e9"

  url "https://github.com/nanot1m/better-win-manager/releases/download/v#{version}/BetterWM-#{version}.zip"
  name "BetterWM"
  desc "Column-based tiling window manager for macOS"
  homepage "https://github.com/nanot1m/better-win-manager"

  depends_on macos: :ventura

  app "BetterWM.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/BetterWM.app"]
  end

  zap trash: [
    "~/.config/betterwm",
    "~/Library/Saved Application State/com.nanot1m.betterwm.savedState",
  ]
end
