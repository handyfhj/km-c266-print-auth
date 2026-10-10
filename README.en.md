# km-c266-print-auth

Reusable solution for **authenticated printing on macOS** with Konica Minolta bizhub C266.
[中文](README.md) | [English](#english)

Fixes jobs cancelled by the device with **"Login Error"** when **device user
authentication** is enabled on a Konica Minolta bizhub printer. Applies when
Windows printing works but macOS printing fails.

**Credentials are entered at install time** (interactive prompt or environment
variables) — never hard-coded in the scripts or docs.

---

## Supported Environment

| Dimension | Description |
|---|---|
| Model | Konica Minolta bizhub C266 (**verified**); same principle applies to same-series models with device user auth (C258 / C308 / C364 / C652, etc.) |
| Auth mode | Device user authentication (AuthType=Device), no account tracking (TrackType=None) |
| macOS | Verified on macOS 27 (Apple Silicon); official PS driver 7.7.0 (Apple notarized, supports macOS 11+) |
| Symptom match | Mac jobs cancelled by the device showing "Login Error"; Windows / direct web printing work fine |

> If the device reports a different error, this solution may not apply — first
> confirm the auth mode and symptom match.

## Symptom

- **Windows**: prints fine (the driver manages credentials and sends a password hash).
- **Direct web printing** (Web Connection): fine.
- **macOS**: every job is cancelled by the device with "Login Error" on the panel.
  IPP / socket(9100) / LPD channels, 8+ PJL variants and `lp -U` all failed.

## Full Troubleshooting Record

Complete step-by-step investigation (sanitized: real usernames, passwords and
the driver password hash are not published here).

### 1. Driver & PPD Environment

- Driver: Mac PS driver `BHC266PSMACOS_770MU.dmg` from the Konica Minolta APAC
  download center (Apple notarized, macOS 11+ / Apple Silicon).
- Active PPD: `/Library/Printers/PPDs/Contents/Resources/KONICAMINOLTAC266.gz`
- Filter: `/Library/Printers/KONICAMINOLTA/C266/Filters/psToKMC266PS`
- Auth template: `/Library/Printers/KONICAMINOLTA/C266/Plist/FilterCustomize.plist`

### 2. Decisive Evidence: Device Job History

Logged into Web Connection with a device user account and read `/wcd/job_history.xml`:

| Source | UserName | Result | Note |
|---|---|---|---|
| Windows driver | user A / user B | End | prints fine, has DriverJobID |
| Direct web print | user A | End | prints fine |
| **macOS driver (all channels)** | user A (parsed correctly) | **Delete / LoginError** | username correct, credentials rejected |

Conclusion: **the device parses the username correctly — the problem is the
password / auth format**, not the username or the network channel.

### 3. Breakthrough Evidence: Windows Print-to-File (.prn)

Printing to file on Windows produced a `.prn` (PCL6, hundreds of KB, 66 PJL
lines). The auth-related PJL block (values sanitized):

```
@PJL SET KMCOETYPE = 2
@PJL SET BOXHOLDTYPE = PRIVATE
@PJL SET KMUSERNAME = "<username>"
@PJL SET KMUSERKEY2 = "<32-hex driver hash>"   ← not plaintext!
@PJL SET KMCERTSERVTYPE = NONE
@PJL SET KMCERTSIMPLEAUTHREQ = OFF
```

Key findings:

- **The Windows driver does not send the plaintext password; it sends a driver
  hash** (32 hex chars, non-standard MD5 — a private Konica Minolta algorithm;
  20+ common candidates such as MD5 were tried and all mismatched).
- The driver also emits `KMCOETYPE = 2`.

### 4. Root Cause Confirmation: External Sources

- GitHub search for `KMUSERKEY2` hits `wbern/room-business-center-skrivare`,
  `docs/km9100auth`, whose conclusion reads:
  **"KMCOETYPE ABSENT (its presence = guaranteed login error)"**.
- Mozilla Bug [1333572](https://bugzilla.mozilla.org/show_bug.cgi?id=1333572):
  Konica Minolta confirms LoginError when the auth PJL is missing, and lists the
  required PJL lines (`KMUSERNAME` + `KMUSERKEY2` etc.).

### 5. Controlled Experiment Matrix

Test jobs over IPP / socket(9100) / LPD, judged by the device job history:

| Password format | KMCOETYPE | Result |
|---|---|---|
| Plaintext | = 2 | **LoginError** (why it kept failing) |
| Plaintext | = 0 | **End ✓** |
| Plaintext | absent | **End ✓** |
| Driver hash | = 2 | **End ✓** (same as Windows) |
| Driver hash | absent | LoginError |

### 6. Root Cause Conclusion

1. The macOS Konica Minolta driver **always injects `@PJL SET KMCOETYPE = 2`**
   into the PJL header, which flips the device into "password = driver hash" mode;
2. On newer macOS the driver's **auth dialog no longer appears** (same root as
   Mozilla Bug 1333572), so no credentials are sent and the password is empty →
   device LoginError;
3. The Windows driver sends the driver hash, so it always worked.

> Two fixes were possible: a) replicate the Windows hash algorithm (not cracked
> — not feasible); b) **strip KMCOETYPE and inject plaintext auth** (the device
> accepts plaintext when KMCOETYPE is absent — chosen).

## Solution

### How it works

A CUPS backend `km9100auth`:

1. Connects to the printer's **9100 port**;
2. Reads the driver-filtered job and **strips stale auth SET lines**
   (BOXHOLDTYPE / KMUSERNAME / KMUSERKEY2 / KMCERTSERVTYPE / KMCERTSERVNUM /
   KMCERTSELECTTYPE / KMCERTSIMPLEAUTHREQ / KMCOETYPE);
3. **Injects the plaintext auth block** right after `@PJL JOB`:
   ```
   @PJL SET BOXHOLDTYPE = PRIVATE
   @PJL SET KMUSERNAME = "<username>"
   @PJL SET KMUSERKEY2 = "<password>"
   @PJL SET KMCERTSERVTYPE = NONE
   @PJL SET KMCERTSIMPLEAUTHREQ = OFF
   ```
4. Sends the rewritten job to the device.

Credentials live in the CUPS queue URI — **no dialog at print time**.

### One-Command Install (enter credentials)

```bash
git clone https://github.com/handyfhj/km-c266-print-auth.git
cd km-c266-print-auth

# Interactive: prompts for IP / username / password (password hidden)
sudo ./install.sh <printer-name>

# Or non-interactive (scripting):
sudo KM_HOST=<ip> KM_USER=<username> KM_PASS=<password> ./install.sh <printer-name>
```

> Prerequisite: the printer is already added in System Settings → Printers with a
> Konica Minolta PPD. The script URL-encodes credentials automatically (e.g.
> Chinese username "技术" → `%E6%8A%80%E6%9C%AF`) and works on both Chinese and
> English macOS.

### Manual Install (equivalent)

```bash
sudo cp km9100auth /usr/libexec/cups/backend/km9100auth
sudo chown root:wheel /usr/libexec/cups/backend/km9100auth
sudo chmod 700 /usr/libexec/cups/backend/km9100auth
sudo launchctl kickstart -k system/com.apple.cupsd

# URL-encode non-ASCII usernames/passwords first
lpadmin -p <printer-name> -v "km9100auth://<url-encoded-user>:<url-encoded-pass>@<ip>"
cupsenable <printer-name>

lpstat -v <printer-name>          # verify device URI
lp -d <printer-name> test.txt     # check Result=End in device job history
```

### Implementation Notes & Pitfalls

| Pitfall | Note |
|---|---|
| Perl string interpolation | `@PJL` in double-quoted strings must be escaped as `\@PJL`, or Perl treats it as array interpolation and compilation fails |
| CUPS disables the printer | When the backend crashes/errors, CUPS marks the printer "disabled"; restore with `cupsenable` |
| Backend sandbox | macOS CUPS backends run sandboxed — **writing to /tmp and similar paths is forbidden**; debug to STDERR (captured by CUPS in error_log) |
| Backend permissions | CUPS only executes files under `/usr/libexec/cups/backend/` owned root:wheel mode 0700 |
| New backend detection | Restart cupsd after installing (`launchctl kickstart -k system/com.apple.cupsd`) |
| `lpstat -v` hides credentials | The display layer hides userinfo; the stored CUPS URI keeps them and the backend parses them fine |

## Verification (measured)

Device job history on the test machine (traceable):

| Job ID | Result |
|---|---|
| 18847 / 18849 / 18851 / 18853 | **End (printed)** |

Windows printing and direct web printing are unaffected.

## Maintenance & Notes

1. **Password change**: just rerun `sudo ./install.sh <printer-name>` and enter
   the new password;
2. **Re-adding the printer in System Settings** auto-discovers a new IPP queue
   that reverts to LoginError — delete the new queue and keep the backend one;
3. **Where credentials live**: URL-encoded in the CUPS queue config (root-readable);
   manage them per your company security policy;
4. The backend applies to other bizhub models with device user auth — just
   change the IP / username / password in the queue URI.

## Files

| File | Description |
|---|---|
| `km9100auth` | CUPS backend script (Perl; perl ships with macOS) |
| `install.sh` | One-command installer (interactive / env-var credentials) |
| `README.md` | 中文说明 |

## References

- Mozilla Bug [1333572](https://bugzilla.mozilla.org/show_bug.cgi?id=1333572):
  official confirmation of the same phenomenon (missing PJL → LoginError)
- [wbern/room-business-center-skrivare](https://github.com/wbern/room-business-center-skrivare):
  original inspiration (KMCOETYPE=2 → login error)
- Konica Minolta official driver downloads: `https://www.btapac.konicaminolta.com/`
