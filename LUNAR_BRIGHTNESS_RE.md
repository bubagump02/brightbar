# Lunar 6.11.2 — contrôle de la luminosité de l'écran intégré (MacBook)

Cible : `/Applications/Lunar.app/Contents/MacOS/Lunar` (universal x86_64 + arm64).
Ce rapport analyse la slice arm64 extraite avec `lipo`, de façon statique uniquement.
Aucune exécution n'a été observée.

Outils : `otool`, `nm`, `swift-demangle`, `objdump --macho` (désassemblage, métadonnées ObjC, function-starts).
Aucun décompilateur (Ghidra/Hopper/IDA) n'était disponible : le rapport s'appuie sur le désassemblage seul.
Les symboles Swift purs sont strippés (`<redacted function>`). Seuls les thunks `@objc` gardent leur nom.
Les fonctions sont donc identifiées par leur adresse arm64.

Légende : **[O]** observé dans le binaire · **[I]** inférence · **[?]** inconnu.

---

## 1. Frameworks privés utilisés [O]

`otool -L` montre que Lunar lie directement :

| Framework | Rôle pour l'écran intégré |
|---|---|
| `DisplayServices.framework` (privé) | API principale : get/set brightness, smooth, linear, notifications |
| `CoreDisplay.framework` | API de repli : `CoreDisplay_Display_{Get,Set}UserBrightness` |
| `SkyLight.framework` (privé) | presets d'écran (XDR "Full Range"), contraste |
| `CoreBrightness.framework` (privé) | `BrightnessSystemClient`, `KeyboardBrightnessClient` |
| `BezelServices` / `OSD` (privés) | OSD de luminosité natif |
| `IOKit` (`IOAVService*`) | DDC/I2C, pour les écrans externes uniquement |

Imports utilisés par le chemin écran intégré :

```
DisplayServicesCanChangeBrightness(CGDirectDisplayID) -> bool
DisplayServicesGetBrightness(CGDirectDisplayID, float *out) -> int   // 0 = OK
DisplayServicesSetBrightness(CGDirectDisplayID, float)      -> int   // 0 = OK
DisplayServicesSetBrightnessSmooth(CGDirectDisplayID, float delta) -> int
DisplayServicesSetLinearBrightness(CGDirectDisplayID, float)
DisplayServicesGetLinearBrightness(CGDirectDisplayID, float *out)
DisplayServicesRegisterForBrightnessChangeNotifications(id, observer, CFNotificationCallback)
CoreDisplay_Display_GetUserBrightness(CGDirectDisplayID) -> double
CoreDisplay_Display_SetUserBrightness(CGDirectDisplayID, double)
```

Les signatures sont **[I]** : elles sont déduites des registres utilisés aux sites d'appel
(`w0` = id, `s0`/`d0` = valeur, `x1` = pointeur de sortie, `w0` en retour testé à 0).

---

## 2. La classe `AppleNativeControl` [O]

Nom ObjC : `_TtC5Lunar18AppleNativeControl`. C'est une classe Swift pure (`_SwiftObject`) de taille 88.
Ivars lues dans les métadonnées ObjC :

| Offset | Nom | Note |
|---|---|---|
| +0x10 | `displayControl` | enum, 1 octet |
| +0x18 | `display` | référence `weak` vers `Display` |
| +0x20 | `$__lazy_storage_$_responsive` | résultat de disponibilité mis en cache |
| +0x28 | `str` | String = `"AppleNative Control"` |
| +0x38 | `method` | enum `AppleNativeMethod` : **0 = CoreDisplay, 1 = DisplayServices** [I] |
| +0x40 | `smoothTransitionTask` | tâche annulable |
| +0x48 | `nitsUpdateRepeater` | timer de rafraîchissement des nits |
| +0x50 | `smoothTransitionWatcher` | surveillance de la transition native |

L'UI dit explicitement : *"The builtin screen brightness can be controlled natively through the macOS internal DisplayServices framework."* [O]

---

## 3. Choix de la méthode : sonde d'écriture — `0x100444eec` [O]

Le thunk `0x10044743c` calcule `responsive` (stocké en +0x20) ainsi :

```swift
responsive = supports(.displayServices) || supports(.coreDisplay)
```

Pseudocode reconstruit de `supports(method)` (`0x100444eec`) :

```swift
func supports(_ m: AppleNativeMethod) -> Bool {
    guard let display else { return false }
    let id = display.id
    if m == .displayServices {
        if DisplayServicesCanChangeBrightness(id) { self.method = .displayServices; return true }
        // sinon : test lecture/écriture
        var b: Float = 0
        guard DisplayServicesGetBrightness(id, &b) == 0 else { return false }
        let probe = b + (b < 0.5 ? 0.01 : -0.01)
        guard DisplayServicesSetBrightness(id, probe) == 0 else { return false }
        var r: Float = 0
        guard DisplayServicesGetBrightness(id, &r) == 0, r == probe else { return false }
        DisplayServicesSetBrightness(id, b)              // restaure
        self.method = .displayServices; return true
    } else {
        let b = CoreDisplay_Display_GetUserBrightness(id)
        let probe = b + (b < 0.5 ? 0.01 : -0.01)
        CoreDisplay_Display_SetUserBrightness(id, probe)
        guard CoreDisplay_Display_GetUserBrightness(id) == probe else { return false }
        CoreDisplay_Display_SetUserBrightness(id, b)     // restaure
        self.method = .coreDisplay; return true
    }
}
```

Les constantes ±0.01 sont observées : `0x3f847ae147ae147b` en double, `0x3c23d70a` en float.
L'ordre est observé : DisplayServices est testé en premier, CoreDisplay sert de repli.

---

## 4. Lecture — `0x1004462cc` [O]

```swift
func getBrightness() -> UInt16? {
    guard let display else { return nil }
    if display.<flag 0x10007ccac> { return display.brightness.uint16Value }  // [?] flag non identifié
    if method == .displayServices {
        var f: Float = 0; DisplayServicesGetBrightness(display.id, &f)
        return UInt16(f * 100)                     // 0x42c80000 = 100.0f
    } else {
        return UInt16(CoreDisplay_Display_GetUserBrightness(display.id) * 100)
    }
}
```

Échelle : Lunar travaille en **0–100**, et l'API native en **0.0–1.0**.

---

## 5. Écriture immédiate — closure `0x1004451f4` [O]

```swift
func write(_ value: Double /*0…1*/) -> Bool {
    let id = display.id
    if method == .displayServices {
        let ok = DisplayServicesSetBrightness(id, Float(value)) == 0
        if ok && value == 1.0 {
            DisplayServicesSetLinearBrightness(id, 1.0)  // force le max linéaire
            async { refreshLinearBrightness/nits }        // -> 0x100445b8c (GetLinearBrightness)
        }
        display.<post-write 0x100084080>(value)          // [I] mise à jour de l'état / des nits
        return ok
    } else {
        CoreDisplay_Display_SetUserBrightness(id, value)
        display.<post-write>(value)
        return true
    }
}
```

L'entrée est un `UInt16` 0–100, converti puis divisé par 100 (`0x4059000000000000` = 100.0).

---

## 6. `setBrightness` du protocole `Control` — `0x100447650` [O]/[I]

Arguments : `brightness: UInt16`, `oldValue: UInt16?` (bit 16 = nil), `transition`, `onChange` closure.

```swift
guard let display, !display.<flag> else { return false }
var t = transition == .default(3) ? CachedDefaults[.brightnessTransition] : transition
if t == .instant || <global flag> || oldValue == nil || oldValue == brightness {
    onChange?(brightness)
    return write(Double(brightness) / 100)
}
// transition douce
display.inSmoothTransition = true                  // 0x10007d120
smoothTransitionTask?.cancel()
smoothTransitionTask = Task("smoothTransitionDisplayServices: …") { smooth(old, new, t) }
```

### Transition — `0x100447bd0` [O]

Deux modes, selon la valeur de `t` :

**a) `t == 2` (lent) [I : nom du cas] : boucle manuelle**
- pas = ±**0.002** (`0x3f60624dd2f1a9fc`, signe selon le sens) ;
- délai entre pas : `NSThread.sleep` de **0.025 s**, ou 0.004 s si `t == 1` ;
- chaque pas appelle `write(v)`, donc `DisplayServicesSetBrightness`, ou CoreDisplay en repli ;
- `onChange(v*100)` est appelé à chaque pas ;
- la boucle est annulable. Le log `"Stopping smooth transition on brightness="` marque la sortie.

**b) Sinon : transition native Apple**
```swift
var cur: Float = 0; DisplayServicesGetBrightness(id, &cur)
DisplayServicesSetBrightnessSmooth(id, target - cur)   // DELTA, pas valeur absolue
nitsUpdateRepeater = Repeater("nitsUpdater", every: 0.05s, times: 10)
smoothTransitionWatcher = "smoothTransitionWatcherAppleNative"(target)
```
Point clé : `DisplayServicesSetBrightnessSmooth` reçoit un **delta** (`fsub s0, target, current`).
Cette fonction anime la luminosité comme le fait macOS avec les touches.

---

## 7. Changements de luminosité externes (touches, ALS) [O]/[I]

- `0x1000bae00` s'abonne via `DisplayServicesRegisterForBrightnessChangeNotifications(id, id, cb=0x1000a3210)`.
  L'abonnement n'a lieu que si `DisplayServicesCanChangeBrightness(id)` est vrai.
  Raisons de refus loggées : `"already observing"`, `"cannot change brightness"`, `"brightness observers disabled"`.
- Le callback CF transmet `(displayID, userInfo)` à `0x1000c2d5c`.
- Ce handler ignore la notification pendant une transition Lunar (`0x100447b7c`) ou si `"screens sleeping"`.
  Sinon il passe sur le main thread pour resynchroniser `display.brightness` **[I]**.
  C'est ainsi que le *Sync Mode* propage la luminosité du MacBook vers les écrans externes.
- Les touches luminosité sont interceptées par des handlers dédiés.
  Le log `"Handling brightness key for \`.builtin\` (lidClosed: …"` est en `0x1002ec028`.
  Il existe aussi des variantes `.external`, `.main`, `.all`, `.cursor`, `.source` et `.nonMain`.

---

## 8. XDR (au-delà de 500 nits, MacBook Pro) [O]/[I]

- **Nouveau mode "Full Range"** (`0x100045e3c`, `0x10004e220`, `0x10004fa94`).
  Lunar lit les presets via `SLSDisplayCopyPresetData` et crée un *"XDR preset"*.
  Il modifie les clés `PresetMaxSDRLuminance`, `PresetMaxHDRLuminance`, `PresetHostMaxSliderBrightness`,
  `PresetHostMaxReferenceLuminance` et `PresetHostDefaultSliderBrightness`.
  Il écrit ensuite le preset avec `SLSDisplaySetPresetData`.
  Cela débloque la plage du slider natif jusqu'à 1600 nits. UI : *"currently locked at 500 nits by the system"*.
- **Ancien mode** : overlay EDR. Indices : `CAMetalLayer` et `maximum{Potential,Reference}ExtendedDynamicRangeColorComponentValue`.
  S'y ajoute une table gamma (`CGSetDisplayTransferByTable` en `0x1000b3474`).
  C'est la même technique que f.lux, d'où l'incompatibilité signalée dans l'UI.
- `DisplayServicesSetLinearBrightness(id, 1.0)` est appelé quand la luminosité atteint 100 %.
  **[I]** Cet appel sert de pont vers la plage XDR/linéaire.

---

## 9. Recette minimale pour reproduire (écran intégré)

```swift
// Lier /System/Library/PrivateFrameworks/DisplayServices.framework
@_silgen_name("DisplayServicesGetBrightness")
func DSGet(_ id: CGDirectDisplayID, _ out: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("DisplayServicesSetBrightness")
func DSSet(_ id: CGDirectDisplayID, _ v: Float) -> Int32
@_silgen_name("DisplayServicesSetBrightnessSmooth")
func DSSetSmooth(_ id: CGDirectDisplayID, _ delta: Float) -> Int32

let id = CGMainDisplayID()          // ou l'écran où CGDisplayIsBuiltin(id) != 0
var cur: Float = 0; _ = DSGet(id, &cur)
_ = DSSet(id, 0.5)                  // immédiat
_ = DSSetSmooth(id, 0.8 - 0.5)      // animé, delta
```

---

## Inconnus / limites

- **[?]** Le flag `0x10007ccac` testé avant toute lecture/écriture n'est pas identifié.
  Candidats : *dummy display*, *blackout* ou *all displays*.
- **[?]** La table complète des cas des enums `BrightnessTransition` et `AppleNativeMethod` manque.
  Seules les valeurs 0/1/2/3 ont été vues ; les noms des cas sont inférés.
- **[?]** La logique de sélection du contrôle (`alternativeControlForAppleNative`, `supportsAppleNative`) n'est que localisée.
  Elle se trouve en `0x10008dad8`, `0x1000952cc` et `0x100327944`, mais n'a pas été décodée.
  Le texte CLI dit : *"Default: CoreDisplay, DDC, Network"*.
- **[?]** L'ordre exact des écritures dans le preset XDR et les valeurs en nits ne sont pas décodés.
- `0x100389b80` et `0x10038b2c0` appellent toute l'API CoreDisplay/DisplayServices.
  Ce sont très probablement les sous-commandes CLI `lunar coredisplay|displayservices <method>` **[I]**.
- Analyse statique seulement : aucun comportement runtime n'a été observé.
