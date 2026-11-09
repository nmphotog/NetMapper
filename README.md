# NetMapper

macOS app (SwiftUI) that scans your local subnet and lists devices with IP, name, MAC and response time, plus a radial map view.

## Run
1. Open `NetMapper.xcodeproj` in Xcode 15 or later (macOS 13+).
2. Press ⌘R. The first scan asks for Local Network permission — click Allow.

## Build a standalone .app
Product → Archive → Distribute App → Copy App. Or from Terminal:

    xcodebuild -project NetMapper.xcodeproj -scheme NetMapper -configuration Release -derivedDataPath build
    open build/Build/Products/Release/NetMapper.app

## How it works
- Finds your active IPv4 interface (en0/en1) and subnet via getifaddrs.
- Probes every address with short TCP connects (a refused connection still proves the host is up).
- Reads the ARP cache to catch firewalled devices and get MAC addresses.
- Reverse-DNS for names. Subnets larger than /22 are limited to your /24.
- App Sandbox is off so it can read the ARP table.
- Export the device list to CSV with the toolbar button or ⌘E.
