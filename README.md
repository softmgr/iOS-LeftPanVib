# LeftPanVib

> A lightweight, high-performance Objective-C dynamic library (`.dylib`) designed for iOS applications (optimized for Bilibili) to implement a native-like **"Right-to-Left Swipe to Go Back"** gesture with precision tactile feedback and intelligent conflict resolution.

---

## ✨ Features

- **🔄 Native-Like Interaction**: Leverages a custom coordinate inversion engine (`LPVReversePanGesture`) to trick the iOS native interactive pop transition engine into granting smooth, fluid transition animations (supports edge scrubbing, hover, and rubber-band bouncing).
- **📳 Precision Haptic Feedback**: Uses iOS native `UIImpactFeedbackGenerator` (Light style, matching system keyboard haptics) coordinated with the system transition engine to vibrate **only** when a navigation pop or full-screen exit actually succeeds.
- **📐 Smart Orientation & Zone Control**: 
  - **Portrait Mode**: Active only in the rightmost $1/3$ of the screen to avoid interfering with central app content.
  - **Landscape Mode**: Tailored for full-screen video players. Restricts the trigger zone to the extreme right edge ($60\,\text{pt}$) and automatically handles full-screen exit by forcing rotation back to portrait.
  - **Game Protection**: Automatically detects and bypasses known game engine rendering views (`Unity`, `OpenGL/EAGL`, `Metal/MTKView`) to prevent accidental triggers during gameplay.
- **⚡ Zero Dependency**: Built purely on standard, stable official `UIKit` and `Objective-C Runtime` APIs. No external dependencies (like CydiaSubstrate or libhooker) required.
- **🛡️ Conflict Resolution**: Overrides lower-level app scroll views and gesture containers (such as Bilibili's comment section or progress bars) via forced touch-delay interception (`delaysTouchesBegan`).

---

## 📱 Compatibility

- **iOS Support**: iOS $14.0+$ (Fully compatible up to the latest iOS versions).
- **Injection Environments**: TrollStore (TrollFools), LiveContainer, SideStore, and custom IPA re-packaging.
- **Architecture**: Standard `arm64` (fully compatible with modern `arm64e` devices).

---

## 🛠️ Configuration Constants

You can easily customize gesture behaviors by modifying the `#define` constants at the top of `leftPan_vib.m`:

```objc
// Trigger Zones
#define kLPVPortraitZoneRatio (2.0 / 3.0) // Active in rightmost 1/3 of portrait screen
#define kLPVLandscapeZoneWidth 60.0      // Active in extreme right edge for landscape

// Success Thresholds
#define kLPVPortraitSuccessTranslationRatio 0.35 // 35% screen width for slow drags
#define kLPVPortraitSuccessVelocity 120.0        // Flick velocity threshold
#define kLPVPortraitMinFlickTranslation 8.0      // Anti-jitter minimum distance
