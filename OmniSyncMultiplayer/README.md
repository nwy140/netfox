# 🌐 Omni Sync — Multiplayer Addon for Godot 4

https://reaver-dev.itch.io/omni-sync

https://www.reddit.com/r/godot/comments/1xkxf6n/i_made_a_godot_4_multiplayer_addon_with/

> **Enterprise-grade peer-to-peer multiplayer with automated quick matching and instant host migration — powered by Epic Online Services (EOS).**

[![Godot Version](https://img.shields.io/badge/Godot-4.3%20%7C%204.7%20%7C%204.8+-blue.svg)](https://godotengine.org)
[![Architecture](https://img.shields.io/badge/Architecture-GDExtension%20(C%2B%2B)-black.svg)](https://godotengine.org)
[![Infrastructure](https://img.shields.io/badge/Server%20Cost-%240%20%2F%20mo%20Forever-brightgreen.svg)](https://dev.epicgames.com)
[![NAT Traversal](https://img.shields.io/badge/NAT%20Punchthrough-STUN%20%2F%20TURN%20%2F%20ICE-orange.svg)](https://dev.epicgames.com)
[![Host Migration](https://img.shields.io/badge/Host%20Migration-Instant%20%2F%20Deterministic-purple.svg)](https://dev.epicgames.com)
[![Platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20Linux%20%7C%20macOS%20%7C%20Android-lightgrey.svg)](https://godotengine.org)

---

## Table of Contents
1. [Overview & Architecture](#-overview--architecture)
2. [Package Contents](#-package-contents)
3. [Quick Start: Test the Demo in 60 Seconds](#-quick-start-test-the-demo-in-60-seconds)
4. [Setting Up Your Free Epic Online Services (EOS) Credentials](#-setting-up-your-free-epic-online-services-eos-credentials)
5. [Integrating Omni Sync into Your Own Game](#-integrating-omni-sync-into-your-own-game)
6. [API Reference: OmniManager](#-api-reference-omnimanager)
7. [Building Gameplay: RPCs & Synchronization](#-building-gameplay-rpcs--synchronization)
8. [Handling Host Migration in Gameplay Logic](#-handling-host-migration-in-gameplay-logic)
9. [Exporting to Mobile (Android)](#-exporting-to-mobile-android)
10. [Supported Platforms & Limitations](#-supported-platforms--limitations)
11. [Troubleshooting & FAQ](#-troubleshooting--faq)

---

## 🚀 Overview & Architecture

Building multiplayer in Godot 4 traditionally presents painful trade-offs:
- **Dedicated VPS Servers:** Cost \$15 to \$150+/month, require Linux devops maintenance, and sit idle when player counts fluctuate.
- **Raw ENet / WebSockets:** Require manual router port forwarding, which fails for over 70% of players behind cellular NATs, college campuses, and home firewalls.
- **Steamworks:** Free, but strictly locks you to Steam on PC — completely preventing mobile or standalone cross-play.

**Omni Sync eliminates all three barriers:**
1. **$0 / Month Server Bills Forever:** Uses Epic Online Services' enterprise global backend. You never pay a cent for server bandwidth or hosting.
2. **True NAT Punchthrough:** Automatically traverses strict firewalls and carrier-grade NATs (CGNAT) using STUN/TURN/ICE socket relays. Players never need to configure routers or open ports.
3. **No Room Codes / IP Typing:** 1-click matchmaking automatically joins existing open lobbies or spins up a new P2P host transparently.
4. **Seamless Host Migration:** If the host player quits, closes their laptop, or loses connection, authority automatically migrates to the next peer in milliseconds. The match continues without kicking players or resetting state.
5. **Native Godot 4 Architecture:** Built directly as a Godot `MultiplayerPeer`. Standard `@rpc`, `MultiplayerSynchronizer`, and `MultiplayerSpawner` work seamlessly out of the box.

---

## 📦 Package Contents

When you unpack Omni Sync, you will find two main directories:

```
OmniSync/
├── Addon/
│   └── addons/
│       └── omni-sync/         <- The standalone addon to drop into any Godot project
│           ├── bin/           <- Precompiled GDExtension C++ binaries (Win/Linux/Mac/Android)
│           ├── heos/          <- High-level EOS classes (HAuth, HLobbies, HP2P, etc.)
│           ├── android/       <- Automated Gradle & deep-linking export plugin
│           ├── scripts/       <- OmniManager.gd & Credentials.gd
│           ├── eos.gd         <- Low-level EOS API bindings
│           ├── runtime.gd     <- EOSGRuntime tick manager
│           ├── plugin.cfg     <- Addon descriptor
│           └── plugin.gd      <- Master plugin orchestrator
└── Project/                   <- Complete, playable multiplayer demo project
    ├── .env                   <- Credentials configuration file
    ├── project.godot          <- Configured Godot 4 project
    └── demo/
        ├── scenes/            <- menu.tscn, game.tscn, player.tscn
        └── assets/            <- Sprites, buttons, Quicksand font, splashscreen
```

---

## ⚡ Quick Start: Test the Demo in 60 Seconds

1. Open **Godot 4.3, 4.7, or 4.8+**.
2. Click **Import** and choose the `Project/project.godot` file inside this package.
3. In Godot, go to **Debug** -> **Customize Run Instances...** and set **Number of Instances** to `2`.
4. Press **F5 (Play Project)**.
5. Two game windows will launch:
   - Click **PLAY** on Window 1 $\rightarrow$ It searches, finds no match, and creates a new P2P server lobby.
   - Click **PLAY** on Window 2 $\rightarrow$ It searches, instantly finds Window 1's lobby, and joins!
   - Both players appear in the arena with synchronized movement, colors, and live ping measurement.
6. **Test Host Migration:**
   - Close Window 1 (the host).
   - Look at Window 2: the ping indicator will briefly flash *"Migrating host..."*, and Window 2 will instantly take over as the new server without dropping out to the menu!

---

## 🔑 Setting Up Your Free Epic Online Services (EOS) Credentials

The demo project includes preconfigured sandbox credentials so you can test right out of the box. 

When you are ready to publish your own game, follow these steps to generate your own free EOS credentials:

### Step 1: Create an Epic Developer Account
1. Go to the [Epic Games Developer Portal](https://dev.epicgames.com/portal/) and log in with your Epic account.
2. If prompted, create an **Organization Name** (e.g., your studio name).

### Step 2: Create a Product
1. On the Developer Portal dashboard, click **Create Product**.
2. Enter your game's name (e.g., *"MyMultiplayerGame"*).

### Step 3: Retrieve Product, Sandbox, and Deployment IDs
1. In your product dashboard, click **Product Settings** (the gear icon on the left menu).
2. Under the **General** tab, you will see:
   - **Product ID** (32-character hex string)
3. Click the **Sandboxes** tab:
   - Copy your **Sandbox ID** (default is usually `Live`).
4. Under your sandbox, click **Deployments**:
   - Copy your **Deployment ID**.

### Step 4: Create a Client Policy & Credentials
1. In the left navigation, go to **Product Settings** -> **Clients**.
2. Click **Add Client Policy**:
   - **Policy Name:** `P2PClientPolicy`
   - **Client Policy Type:** Select `Peer2Peer` or `Custom`.
   - Ensure the following feature permissions are checked:
     - ☑ **Lobbies (Matchmaking, Read, Write)**
     - ☑ **P2P (Connect, Read, Write)**
     - ☑ **User Auth / Connect (Basic Profile)**
   - Click **Save**.
3. Go back to the **Clients** tab and click **Add New Client**:
   - **Client Name:** `GameClient`
   - **Client Policy:** Select `P2PClientPolicy` (created in the previous step).
   - Click **Save**.
4. You will now see:
   - **Client ID** (alphanumeric string)
   - **Client Secret** (long base64 string)

### Step 5: Generate an Encryption Key
Under **Product Settings** -> **General**, locate the **Encryption Key** field. Click **Generate** to create a 64-character hexadecimal key.

---

## 🛠️ Integrating Omni Sync into Your Own Game

Adding Omni Sync to an existing Godot project takes less than 2 minutes:

### Step 1: Copy the Addon
Copy the `Addon/addons/omni-sync/` folder into your project's `res://addons/` directory:
```
your-project/
├── addons/
│   └── omni-sync/
├── .env
└── project.godot
```

### Step 2: Enable the Plugin
1. Open your project in the Godot editor.
2. Go to **Project** -> **Project Settings...** -> **Plugins**.
3. Locate **Omni Sync** and check ☑ **Enable**.
4. The plugin automatically registers the required autoload singletons in the correct dependency order:
   - `EOSGRuntime`
   - `HPlatform`
   - `HAuth`
   - `HLobbies`
   - `HP2P`
   - `OmniManager`
   - `EnvLoader`

### Step 3: Add Your `.env` File
Create a `.env` file in your project's root folder (`res://.env`) with your credentials:

```ini
PRODUCT_NAME=MyAwesomeGame
PRODUCT_VERSION=1.0.0
PRODUCT_ID=your_product_id_here
SANDBOX_ID=your_sandbox_id_here
DEPLOYMENT_ID=your_deployment_id_here
CLIENT_ID=your_client_id_here
CLIENT_SECRET=your_client_secret_here
ENCRYPTION_KEY=your_64_char_encryption_key_here
```

*(Note: If no `.env` file is present, `addons/omni-sync/scripts/Credentials.gd` falls back to the default fallback values or your project settings).*

---

## 📡 API Reference: OmniManager

The `OmniManager` singleton is your central orchestrator. You do not need to interact with raw EOS C++ pointers or handle low-level sockets.

### Core Methods

| Method | Parameters | Description |
| :--- | :--- | :--- |
| `search_for_match()` | `bucket_id: String = "QUICKMATCH"` | Starts automated matchmaking. Searches for an open lobby in the bucket. If found, joins it; if none exist, creates a new P2P host. |
| `leave_match()` | *none* | Gracefully leaves the active session, closes P2P sockets, notifies peers, and clears the multiplayer peer. |
| `get_host_latency_ms()` | *none* | Returns the real-time roundtrip ping to the host in milliseconds. Returns `-1` if not connected or if local client is the host. |
| `get_player_slot(peer_id)`| `peer_id: int` | Returns a consistent `0`-indexed player slot number for the given Godot peer ID (ideal for assigning player spawn colors, IDs, or start pads). |

### Core Signals

```gdscript
# Emitted when the Epic Online Services SDK initializes and authenticates with a Product User ID (PUID)
signal eos_ready

# Emitted when human-readable matchmaking status changes (e.g., "Searching...", "Creating lobby...", "Connecting to peer...")
signal matchmaking_status_changed(status_text: String)

# Emitted when an open lobby has been located or established
signal match_found

# Emitted when all peers are connected, socket handshakes are verified, and gameplay is ready to begin
signal match_started

# Emitted when the host disconnected and a new host peer authority was established
signal host_migrated(new_host_peer_id: int)

# Emitted when the match ended or local player left
signal match_ended
```

---

## 🎮 Building Gameplay: RPCs & Synchronization

When `OmniManager.match_started` is emitted, `multiplayer.multiplayer_peer` is already assigned to a fully connected P2P peer.

You write your multiplayer gameplay exactly like standard Godot 4:

### 1. Spawning Players
```gdscript
extends Node2D

@export var player_scene: PackedScene

func _ready() -> void:
    OmniManager.match_started.connect(_on_match_started)

func _on_match_started() -> void:
    # Only the host spawns authority nodes
    if multiplayer.is_server():
        # Spawn host player
        _spawn_player(multiplayer.get_unique_id())
        
        # Spawn all connected client players
        for peer_id in multiplayer.get_peers():
            _spawn_player(peer_id)

func _spawn_player(peer_id: int) -> void:
    var player = player_scene.instantiate()
    player.name = str(peer_id)
    # Set network authority to the controlling peer
    player.set_multiplayer_authority(peer_id)
    $Players.add_child(player, true) # true enables MultiplayerSpawner sync
```

### 2. Player Input & Synchronization
Inside your `player.gd`:
```gdscript
extends CharacterBody2D

const SPEED = 300.0

func _physics_process(delta: float) -> void:
    # Only the owner processes local input
    if is_multiplayer_authority():
        var dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
        velocity = dir * SPEED
        move_and_slide()
```

Add a `MultiplayerSynchronizer` child node to `player.tscn` replicating:
- `.:position`
- `.:velocity`

---

## 🔄 Handling Host Migration in Gameplay Logic

Omni Sync handles the complex networking handshake during host migration automatically. When the host leaves:
1. `OmniManager` detects the server disconnection.
2. The remaining peer with the lowest EOS Product User ID deterministically promotes itself to the new Server (`create_server`).
3. Other peers connect to the new server's P2P socket.
4. `OmniManager` emits `host_migrated(new_host_id)`.

To handle this cleanly in your game scene:

```gdscript
func _ready() -> void:
    OmniManager.host_migrated.connect(_on_host_migrated)

func _on_host_migrated(new_host_id: int) -> void:
    print("Authority migrated to peer: ", new_host_id)
    
    if multiplayer.is_server():
        # We are now the host!
        # Re-assign authority over global game managers or AI if needed
        $LevelManager.set_multiplayer_authority(multiplayer.get_unique_id())
    
    # Remove the old disconnected host's player avatar if it still exists
    for child in $Players.get_children():
        var id = child.name.to_int()
        if id != multiplayer.get_unique_id() and id not in multiplayer.get_peers():
            child.queue_free()
```

---

## 📱 Exporting to Mobile (Android)

Omni Sync includes an **automatic Android export plugin** that configures Gradle, native libraries, and deep-link schemes with zero manual XML editing.

### Exporting Steps
1. In Godot, go to **Project** -> **Install Android Build Template...** (if you haven't already).
2. Go to **Project** -> **Export...** and add the **Android** preset.
3. Check ☑ **Use Gradle Build**.
4. Under **Permissions**, enable:
   - ☑ **Internet**
   - ☑ **Access Network State**
5. Click **Export Project** and select your output `.apk`.

> **What the Export Plugin does automatically:**
> - Injects the `eossdk-StaticSTDC-release.aar` library into your `android/build/build.gradle`.
> - Updates `minSdk` to 23 in `config.gradle`.
> - Injects `System.loadLibrary("EOSSDK")` and `EOSSDK.init(this)` into `GodotApp.java`.
> - Registers the `eos.<client_id>://` OAuth callback schema.

---

## 🖥️ Supported Platforms & Limitations

| Platform | Support | Notes |
| :--- | :---: | :--- |
| **Windows** | ✅ Fully Supported | x86_64 precompiled binaries. Pre-bundled with `xaudio2_9redist.dll`. |
| **Linux** | ✅ Fully Supported | x86_64 and arm64 precompiled binaries. |
| **macOS** | ✅ Fully Supported | Universal binary (Intel & Apple Silicon). |
| **Android** | ✅ Fully Supported | arm64 and x86_64 with automated Gradle configuration. |
| **Web / HTML5** | ❌ Not Supported | **Reason:** Epic Games' EOS C SDK is a native desktop/mobile library and does not compile to WebAssembly. Browsers cannot load native EOS sockets. |
| **iOS** | ⚠️ Static Framework | Native binaries included in `bin/ios/`, but requires static linking via Xcode with EOS entitlement certificates. |

---

## ❓ Troubleshooting & FAQ

### Q: Why does the console say "No lobbies found. Creating a new one..."?
**A:** This is normal and expected! Omni Sync's auto-matchmaker searches for open lobbies matching your `bucket_id`. If nobody is currently hosting an open match, it automatically creates a new lobby and turns your client into the P2P host. The next player who hits Play will join your match.

### Q: Does Omni Sync require players to have the Epic Games Launcher installed?
**A:** **No!** Omni Sync uses Epic Online Services (EOS) **Device ID authentication**. It runs completely standalone in your game. Players do not need an Epic account, an Epic launcher, or any third-party app installed.

### Q: What is the maximum player count per lobby?
**A:** By default, lobbies are set to 4 players in the demo. You can configure `max_lobby_members` in `OmniManager.gd` up to 64 players for P2P matches (depending on the host's upload bandwidth).

### Q: Do I need to open ports on my router?
**A:** **No.** EOS handles NAT traversal using STUN/TURN relays and ICE candidate exchange. Connections work automatically through standard home Wi-Fi, 4G/5G mobile hotspots, and corporate networks.

---

## 📄 License

Omni Sync is released under a **perpetual, royalty-free commercial license** for purchasers. 
- You may use Omni Sync in an unlimited number of commercial and personal projects.
- You do not owe royalties or subscription fees.
- You may not resell or redistribute the raw Omni Sync addon source code as a standalone asset pack.
