# Web Survey: browser asset inventory and migration proposal

Lane 3 deliverable (inventory and proposal only). Product code was not changed, built or hosted.
Source: the `Epi-Info-Web-Survey` worktree at branch `copilot/websurvey-browser-inventory` (same content as `copilot/build-and-test-baseline`).
Paths are relative to `Epi.Web/` unless another project is named.

Each fact is marked with one of these labels:

| Label | Meaning |
|---|---|
| **V** | Verified: read in source, checked on disk, or confirmed by an advisory database or official doc. |
| **I** | Inferred: from documented MVC/jQuery behavior or static reasoning; not run. |
| **U** | Unknown. |

Related: [PRIORITIES.md](PRIORITIES.md) item 3, [MODERNIZATION.md](MODERNIZATION.md) Phase 1 (Bootstrap/jQuery and jQuery Mobile rows), [BUILDING.md](BUILDING.md) (root `Web.config` absent; views/hosting not validated).

## 1. Method

- **Views read:** every `.cshtml` file under `Views/`, including `.Mobile.cshtml` variants. The project has no `.aspx`, `.ascx`, `.master` or `.html` views. **V**
- **References traced:** `<script>`, `<link>` and `Url.Content` references, and `Scripts.Render` / `Styles.Render`. There are no Render calls anywhere. **V**
- **Script emission searched:** dynamic script injection in JS (`createElement('script')`, `getScript`, `document.write`) — none found **V**. Also searched C# that emits JS: `Epi.DynamicForms.Core/Fields/*.cs` and `Epi.Web.CheckCodeEngine` `Rule_*.ToJavaScript`.
- **Versions:** taken from file header comments.
- **Advisories:**
  - OSV API queries per npm package and version.
  - npm registry for the latest versions.
  - unpkg/jsDelivr resolution for unpinned CDN URLs.
- **Breaking-API counts:** regex scans that exclude `//` comment lines. They are counts of call sites, not proof of failure.

## 2. Layouts and which views use them

| Layout | Selected by | Views/actions | Mobile variant |
|---|---|---|---|
| `Views/Shared/_Layout.cshtml` | `_ViewStart.cshtml:2`, plus explicit `Layout=` in AccessDenied, Final/Index, Home/Default, Home/Index, Login/Index, Response/Index, Error, Exception, IsSubmitedError, SurveyClosedError, Survey/Index | Default for all of these, and for Account/Index and Print/Index through `_ViewStart` **V** | `_Layout.Mobile.cshtml`, picked by display-mode-aware layout lookup (Web Pages 2) **I** |
| `Views/Shared/_Layout.Mobile.cshtml` | Mobile display mode (§5) | Home/Index.Mobile, Login/Index.Mobile, Survey/Index.Mobile, Final/Index.Mobile, FormResponse/Index.Mobile, Shared/Exception.Mobile **V** | n/a |
| `Views/Shared/_LayoutPage2.cshtml` | `SurveyManager/Index.cshtml:4` | Survey manager (admin) **V** | none: same layout on mobile **I** |
| `Views/Shared/_LayoutPage3.cshtml` | `Report/Index.cshtml:5` | Reports/dashboard **V** | none |
| (no layout) | `PartialView` | Survey/Print, Survey/ListResponses **V** | n/a |

Structural defects found:

- **Orphan mobile view.** `EIWST/View.Mobile.cshtml` has no desktop counterpart, and the controller returns `INDEX_PAGE`. **V**
- **Missing desktop view.** `FormResponseController.cs:89` returns `View("Index")`, but only `FormResponse/Index.Mobile.cshtml` exists, so desktop user agents probably get a view-not-found error. **I**
- **Missing partial.** `PagerPartial` is referenced at `FormResponse/Index.Mobile.cshtml:702` and `:747`, `Survey/ListResponses.cshtml:156` and `Survey/ListResponsesOld.cshtml:153`, but it is neither on disk nor in the csproj. **V**

## 3. Assets actually served, per layout, in load order

### 3.1 `_Layout.cshtml` (desktop survey)

Line 7 is `X-UA-Compatible` (IE-era).

| Order | Line(s) | Asset (file on disk) | Version (header) | Exists |
|---|---|---|---|---|
| 1 | 8 | Scripts/jquery-1.7.1.js | jQuery 1.7.1 | V |
| 2 | ~9–10 | jquery.validationEngine.js + -en.js | validationEngine 2.2.4 | V |
| 3 | | jquery.numeric.js | unversioned **U** | V |
| 4 | | jquery.maskedinput-1.3.js | 1.3 | V |
| 5 | | jquery-ui-1.8.16.custom.min.js | jQuery UI 1.8.16, full build (all widgets and effects) | V |
| 6 | | jquery.ui.mouse.js, jquery.ui.dialog.js, jquery.ui.position.js, jquery.bgiframe-2.1.2.js, jquery.ui.core.js, jquery.ui.widget.js | UI **1.8.17** single files; bgiframe 2.1.2 | V |
| 7 | | jquery.Epi.Survey.Components.js, CheckCodeEngineV1.js, jquery.PreventEnter.js | Epi-authored | V |
| 8 | | idle-timer.js, jquery-ui-sliderAccess.js, jquery-ui-timepicker-addon.js, jquery.idletimeout.js, jquery.idletimer.js | sliderAccess 0.2, timepicker 0.9.9, idletimeout 1.2, idletimer 0.8.092209 | V |
| 9 | | Print.js (Epi), awesomplete.css/js | awesomplete unversioned **U** | V |
| 10 | ≤36 | page.css, validationEngine.jquery.css, ui-lightness/jquery-ui-1.8.16.custom.css, jquery.ui.all.css (1.8.17; @imports base → core, dialog, theme) | | V |
| 11 | ≤36 | `https://www.google.com/recaptcha/api.js` (async defer; https; no SRI, as is normal for reCAPTCHA) | external | V |
| 12 | 38–50 | `CUSTOM_THEME=="CLASSIC"` ? epistyle.css + epistyle_controls.css : epistyle-blue.css + epistyle-blue_controls.css | Epi | V |
| 13 | 53 | jquery.tools.min.js | jQuery Tools 1.2.7 (tooltip) | V |

Notes:

- **Mixed jQuery UI versions.** The 1.8.17 core, widget, mouse, dialog and position files load after the full 1.8.16 build and redefine it. **V**
- **Theme.** The tracked stale `bin/Epi.Web.MVC.dll.config:69` sets `BLUE`. The real deployed value is **U**.
- **Dead CSS hook.** The `PIE.htc` `behavior:` rules in `epistyle-blue*.css` are all inside comments. **V**

### 3.2 `_Layout.Mobile.cshtml`

| Order | Line(s) | Asset | Version | Exists |
|---|---|---|---|---|
| 1 | 8–17 | Content/jquery.mobile-1.1.1.css, jquery.mobile.structure-1.1.1.css, Site.Mobile.css, MobilePage.css, validationEngine.jquery.Mobile.css, TabletEpiStyle.css, awesomplete.css | JQM 1.1.1 | V |
| 2 | 18 | Scripts/mobileautocomplete.js (vanilla fork of awesomplete; loads before jQuery) | U | V |
| 3 | 20 | **jquery-1.6.3.min.js** | 1.6.3 | V |
| 4 | 21 | **jquery-1.7.1.js**, which replaces the 1.6.3 global; the duplicate load is dead weight | 1.7.1 | V |
| 5 | 22–31 | validationEngine + en, numeric, maskedinput-1.3, Components, CheckCodeEngineV1, PreventEnter, jquery-ui-sliderAccess (**jQuery UI is not loaded in this layout**), jquery.tools | as §3.1 | V |
| 6 | 32–37 | inline `mobileinit` handler: `$.mobile.ajaxEnabled = false` | | V |
| 7 | 39–44 | jquery.mobile-1.1.1.js; jquery.mobile.datebox-1.0.1.js (`1.0.1-2012022700`) + css; jquery.mobile.simpledialog.min css/js (`1.0.1-2012021300`); jquery.mobile.simpledialog2.min.js (`1.0.1-2012061300`) | | V |
| 8 | 46–53 | MobileEpiStyle.css (CLASSIC) or mobile-epistyle-blue.css | Epi | V |
| – | 131 | `_ViewSwitcher` partial is commented out | | V |

### 3.3 `_LayoutPage2.cshtml` (SurveyManager)

- **Lines 8–32:** the same local stack as `_Layout`, except it serves **CheckCodeEngine.js** instead of V1, and has no page.css or theme CSS. **V**
- **Line 34:** Google Fonts Material Icons (https). **V**
- **Lines 35 and 37:** epiwebsurvey_admin.css, then Content/css/bootstrap.min.css (**Bootstrap 4.2.1**). **V**
- **Lines 39–40:** jquery.tools, then Scripts/bootstrapV4.min.js (4.2.1). This is not the bundle build and **no Popper** is loaded. **V**
- **Bootstrap JS throws at load.** Bootstrap 4.2.1 JS contains a guard that throws `"Bootstrap's JavaScript requires at least jQuery v1.9.1"`. The guard is in the minified file **V**. The page runs jQuery 1.7.1, so the guard throws: statically deterministic, not run **I**. Bootstrap JS components on this page (dropdowns, modals, tooltips) therefore do not initialize. CSS still applies.
- **View-level scripts in `SurveyManager/Index.cshtml`:**

  | Line(s) | Asset | Version / pinning | Status |
  |---|---|---|---|
  | 6–10 | c3.min.js | C3 0.7.15 | **V** |
  | 6–10 | d3-5.8.2.min.js | d3 5.8.2 | **V** |
  | 6–10 | `https://unpkg.com/xlsx/dist/xlsx.full.min.js` | **unpinned**, no SRI; currently resolves to xlsx 0.18.5 | **V** (resolution checked) |
  | 6–10 | `https://cdn.jsdelivr.net/npm/json2csv` | **unpinned**, no SRI; currently 5.0.7 | **V** (`x-jsd-version` header) |
  | 12–14 | jloading-overlay, jquery-1.9.1 | commented out | **V** |

### 3.4 `_LayoutPage3.cshtml` (Report)

- **Lines 10–34:** the local stack is entirely commented out. **V**
- **Lines 40–41:** two CDN scripts over https, with **no SRI and no crossorigin**: **V**
  - `https://code.jquery.com/jquery-1.12.4.js`
  - `https://code.jquery.com/ui/1.12.1/jquery-ui.js`
- **Lines 42–45:**
  - bootstrap.min.css 4.2.1
  - jquery.tools.min.js
  - bootstrapV4.min.js 4.2.1. jQuery 1.12.4 satisfies its guard. **V**
- **Tooltip collision:** `$.fn.tooltip` is defined by jQuery UI 1.12, then jQuery Tools, then Bootstrap, so the last loaded (Bootstrap) wins. **I**
- **View-level assets (`Report/Index.cshtml:7–10`):** c3.min.js 0.7.15, d3-5.8.2.min.js, wordcloud2.js (version **U**), c3.min.css. **V**

### 3.5 Other served or emitted script

- **Omniture.** `OmniturePartial.cshtml:4–5` takes the script src from config keys `OMNITURE_TOPIC_LEVEL_JS` and `S_CODE_JS`. The URL and its http/https scheme are **U**. The partial is rendered from Home/Index:246, Home/Index.Mobile:278, Final/Index:155 and Final/Index.Mobile:85. The stale config has `OMNITURE_IS_ENABLED=FALSE`.
- **C#-emitted inline jQuery (`Epi.DynamicForms.Core/Fields/*.cs`).** This code runs inside whichever layout's jQuery is loaded.
  - **Mobile datebox:** `MobileDatePicker.cs:189` emits `data-role="datebox"`.
  - **Check-code bindings:** CheckCodeEngine `Rule_*.cs` has 69 files with `ToJavaScript`. They emit calls to `CCE_*` functions defined in CheckCodeEngineV1.js / CheckCodeEngine.js.
- **Not present anywhere:** `jQuery.noConflict`, `Scripts.Render` and `Styles.Render`. **V**

## 4. Declared vs served vs on disk

### 4.1 `packages.config` against reality

| Package (declared) | Content on disk | Served version | Finding |
|---|---|---|---|
| jQuery **3.5.0** | **no** jquery-3.5.0 file; `packages/` has no jQuery.3.5.0 | 1.7.1 (desktop/admin, mobile), 1.6.3 (mobile, overwritten), 1.12.4 CDN (report) | Dependabot bump fb9023b3 (2023-05-31, merged 32461d5a 2024-11-29) changed only the manifest. **The manifest misreports the security posture.** **V** |
| bootstrap **3.4.1** | Content/bootstrap*.css and Scripts/bootstrap*.js are **3.3.7** | 4.2.1 (Content/css + bootstrapV4) | Dependabot a3ed09a2 changed only the manifest. 3.3.7 files are unserved; 4.2.1 is served but undeclared. **V** |
| jQuery.Validation **1.19.4** | Scripts/jquery.validate.js header says **1.6** | none | Dependabot b9383510 changed only the manifest. Unserved. **V** |
| jquery.mobile 0.5.3 | jquery.mobile-1.0b3 and 1.1.1 files | 1.1.1 | Served version undeclared. **V** |
| jQuery.UI.Combined 1.8.12 | jquery-ui-1.8.12(.min).js, themes/base 1.8.12 | 1.8.16 custom + 1.8.17 parts; 1.12.1 CDN | 1.8.12 unserved. **V** |
| Modernizr 2.0.6, knockoutjs 2.0.0, jQuery.vsdoc 1.6, Microsoft.jQuery.Unobtrusive.Ajax/Validation 2.0.20505 | present | none | Declared but unserved. **V** |
| Microsoft.AspNet.Web.Optimization 1.0.0-beta2, WebGrease | DLL refs | bundles never rendered | Dead runtime path (see 4.2). **V** |

- **`packages/` folder:** 150 tracked files, including jQuery.1.5.1, jQuery.1.7, jquery.mobile.0.5.3, jQuery.Mobile.MVC.0.0.2, jQuery.Validation.1.8.0/1.8.1, knockoutjs, Modernizr.1.7/2.0.6 and unobtrusive. It does not match packages.config. **V**
- **Unobtrusive validation is off in practice.** `Account/Index` uses `Html.ValidationMessageFor`, and the stale config sets `ClientValidationEnabled` / `UnobtrusiveJavaScriptEnabled` to true. But jquery.validate and unobtrusive are never served, so validation is server-side only. **V**/**I**

### 4.2 BundleConfig

- **Registration.** `App_Start/BundleConfig.cs:10–37` registers the following, and is called from `Global.asax.cs:56`: **V**

  | Bundle | Source |
  |---|---|
  | `~/bundles/jquery` | `~/Scripts/jquery-1.*` (the wildcard would match the 1.5.1, 1.6.x, 1.7.1 and 1.9.1 files) |
  | `~/bundles/jqueryui` | |
  | `~/bundles/jqueryval` | |
  | `~/bundles/modernizr` | |
  | `~/Content/css` | site.css |
  | `~/Content/themes/base/css` | 1.8.12 theme CSS |

- **Never rendered.** No view renders any of these bundles. **V**

### 4.3 csproj and the file system

- **Content list.** `Epi.Web.csproj` lists 300 Scripts/Content/Views items, and all exist on disk. **V**
- **On disk but not in the csproj:** Content/css/bootstrap.txt, about 27 images, and Content/Text/EmailList-Bulk.xlsx. **V**
- **Framework references:** TargetFramework v4.8, MVC 4.0, WebPages 2.0, and Microsoft.Web.Mvc.FixedDisplayModes 1.0.1 (csproj:99). **V**
- **FixedDisplayModes not wired up.** No `FixedRazorViewEngine` is registered in code. **V**
- **Second project file.** `Epi.Web_Bad.csproj` also exists. **V**
- **Missing file:** `PagerPartial` (§2). **V**

**Orphaned (on disk, not served by any layout or view). All V.**

| Area | Files |
|---|---|
| jQuery | Scripts/jquery.js (v1.3.2), jquery-1.5.1(.min), jquery-1.6.2.min, jquery-1.6.3.js, jquery-1.6.3-vsdoc, jquery-1.6.min.js (header says **1.6.4**), jquery-1.9.1(.min/.map/.intellisense), `_references.js` (references 1.9.1) |
| jQuery UI | jquery-ui-1.8.12(.min).js, Scripts/jquery.ui.all.css, Content/themes/base/* (1.8.12), Content/css/jquery-ui-1.8.16.custom.css (the ui-lightness copy is the one served) |
| jQuery Mobile | jquery.mobile-1.0b3(.min) js+css, jquery.mobile-1.1.1.min.js, jquery.mobile*.min.css, jquery.mobile.theme-1.1.1(.min).css, themes/D(.min).css, EpiTheme(.min).css, jqm-datebox.core.js, jqm-datebox.mode.flipbox.js, jqm-datebox.css, jqm-docs.js, demos.css |
| Bootstrap and frameworks | Scripts/bootstrap(.min).js and Content/bootstrap*.css (3.3.7), knockout-2.0.0, modernizr-2.0.6-development-only, PIE.htc |
| Validation | jquery.validate*, jquery.unobtrusive-ajax*, jquery.validate.unobtrusive* |
| Epi | MobileCheckCodeEngine.js |
| Other plugins | autoNumeric-1.7.4.js, jloading-overlay.js/.css, jquery.number_format.js, jquery.simpledialog.0.1.min.js/.css |
| Other CSS | Site.css (BundleConfig only) |

## 5. Mobile display modes

`Global.asax.cs:51–53` inserts three `DefaultDisplayMode("Mobile")` entries at index 0. They are inserted in the order Android, Opera Mobi, iPad. **V**

| Eval order | ContextCondition | Result |
|---|---|---|
| 1 | `context.Request.UserAgent` contains `"iPad"` | Mobile **V** |
| 2 | UA contains `"Opera Mobi"` | Mobile **V** |
| 3 | UA contains `"Android"` | Mobile **V** |
| 4 | built-in MVC "Mobile" mode: `GetOverriddenBrowser().IsMobileDevice` (browser caps) | Mobile **I** (MVC 4 default) |
| 5 | default | desktop |

Lines 48–49 and 59–68 are commented-out older variants (separate Android/Opera modes and a broad combined condition). **V**

**Consequences**

- **Overrides can't force desktop.** The three custom conditions read the raw User-Agent and **ignore the browser override**, so a "Desktop" override cannot force desktop on Android, iPad or Opera Mobi. Only mode 4 honours it. **V** (code) / **I** (runtime)
- **Null User-Agent probably throws.** The conditions have no null check, so a request without a User-Agent probably throws `NullReferenceException` during view lookup. **I**
- **The view switcher is unreachable.** `ViewSwitcherController.cs:8–15` calls `SetOverriddenBrowser` / `ClearOverriddenBrowser`, which store a cookie (default `.ASPXBrowserOverride`, **I**). It then calls `Redirect(returnUrl)` without validating the URL, which is an **open redirect** if the action is reachable.
  - `RouteConfig.cs` has no generic `{controller}/{action}` route; the default route is commented out at lines 23–27 and at the end of the file. **V**
  - There is no ViewSwitcher route. **V**
  - The `_ViewSwitcher` partial is commented out (`_Layout.Mobile.cshtml:131`). **V**
  - So the switcher is unreachable. **I**
- **A second, independent mobile flag drives field rendering.** Controllers compute it separately from the display mode. **V**
  - `SurveyController.cs:80–89` sets it from `Request.Browser.IsMobileDevice || SurveyHelper.IsMobileDevice(UA)`.
  - `SurveyHelper.cs:403` matches `Opera Mobi`, `Android`, `Mobile`, `Phone` or `Opera Mini`, and `IsAndroid` is a substring check.
  - `Utility/FormProvider.cs:22–47` uses the flag to set `form.IsMobile`, which selects the `Mobile*` field renderers (datebox, JQM checkboxradio refresh).
  - The two flags can disagree. An iPhone (`Mobile` token) always gets the mobile fields, but gets the mobile *layout* only if browser caps report it as mobile. **I** If it gets the desktop layout, the mobile renderers call JQM/datebox APIs that are not loaded.

**Modern user agents**

| Client | UA today | Layout | Field renderers |
|---|---|---|---|
| iPadOS 13+ Safari (not mini) | desktop macOS UA, no `iPad` token ([WebKit Safari 13](https://webkit.org/blog/9674/new-webkit-features-in-safari-13/)) **V** | **desktop** **I** | desktop **I** |
| Android phone | contains `Android` and `Mobile` | mobile | mobile |
| Android tablet | contains `Android` | **mobile** (tablets get the phone UI) | mobile |
| iPhone | `iPhone … Mobile` | depends on browser caps **U** | mobile |
| Opera Mobile | `Opera Mobi` (rare today) | mobile | mobile |
| Chrome "Request desktop site" on Android | desktop Linux UA | desktop | desktop |

**Mobile-only latent defects**

- **`.dialog("open")` probably fails.** In the mobile layout, `$.fn.dialog` is jQuery Mobile's `mobile.dialog` widget (`jquery.mobile-1.1.1.js:4100`), which has `close` but no `open`. Mobile views call `.dialog({...})` / `.dialog("open")` (e.g. around `Survey/Index.Mobile.cshtml:349` and `:465`), which probably throws or does nothing. **I**
- **Autocomplete probably throws.** `Survey/Index.Mobile.cshtml:850` calls `$(…).autocomplete`, but jQuery UI is not loaded in the mobile layout. **I**
- **sliderAccess has no dependency.** jquery-ui-sliderAccess loads in the mobile layout without jQuery UI. It is harmless unless called. **I**

## 6. Plugins and breaking-API usage

### 6.1 Plugin stack, per layout

| Plugin | Version | Served on | Depends on | Status |
|---|---|---|---|---|
| jQuery UI (full custom + core/widget/mouse/dialog/position) | 1.8.16 + 1.8.17 | _Layout, _LayoutPage2 | jQuery ≤1.8 (uses `$.browser`, `$.curCSS`, `.andSelf`) | blocks jQuery 1.9+ |
| jQuery UI (CDN) | 1.12.1 | _LayoutPage3 | jQuery 1.7+ | ok on 1.12.4 |
| jQuery Mobile | 1.1.1 | _Layout.Mobile | jQuery **1.6.4 or 1.7.1 only** ([JQM 1.1.1 notes](https://blog.jquerymobile.com/2012/07/12/jqm-1-1-1/)) **V** | abandoned project |
| datebox / simpledialog / simpledialog2 | 1.0.1 (2012) | _Layout.Mobile | JQM 1.1 | abandoned |
| validationEngine | 2.2.4 | all except _LayoutPage3 | `.live`/`.die` | breaks on 1.9+ |
| maskedinput | 1.3 | all except _LayoutPage3 | `$.browser` at **load** | breaks on 1.9+ |
| bgiframe | 2.1.2 | _Layout, _LayoutPage2 | `$.browser` at **load**; IE6-only purpose | delete |
| timepicker-addon / sliderAccess | 0.9.9 / 0.2 | _Layout, _LayoutPage2 (+ sliderAccess on mobile) | jQuery UI slider/datepicker | old |
| idletimeout / idletimer / idle-timer.js | 1.2 / 0.8.092209 / U | _Layout, _LayoutPage2 | jQuery UI dialog | old |
| jQuery Tools | 1.2.7 (tooltip) | all four | no hits in the scan | name collision on `$.fn.tooltip` |
| Bootstrap | 4.2.1 | _LayoutPage2, _LayoutPage3 | jQuery ≥1.9.1 and Popper (not loaded) | **broken on _LayoutPage2** |
| awesomplete / mobileautocomplete | U | _Layout, _LayoutPage2 / mobile | none (vanilla) | ok |
| c3 / d3 / wordcloud2 | 0.7.15 / 5.8.2 / U | SurveyManager, Report | none | old, no advisories |
| Modernizr | 2.0.6 | **not served** | | |

**Check-code runtime.** The check-code runtime is Epi-authored JS, and the copy served depends on the layout: **V**

- **`CheckCodeEngineV1.js`**: served by the survey layouts (`_Layout` and `_Layout.Mobile`).
- **`CheckCodeEngine.js`**: served by `_LayoutPage2`.
- **`MobileCheckCodeEngine.js`**: on disk but orphaned.

The C# `Rule_*.ToJavaScript` output calls its `CCE_*` functions. The runtime is coupled to the following:

- validationEngine `hidePrompt` (`CheckCodeEngineV1.js:2746`)
- datebox: 12 calls, e.g. `:1190` `datebox('disable')`
- JQM `checkboxradio("refresh")` (`:1512`, `:1517`)
- jQuery UI datepicker/timepicker

### 6.2 Breaking-API call sites (non-comment)

Target: jQuery 1.9 (removals) and 3.x. Counts are call sites. **V** (grep); whether each one breaks at runtime is **I**.

| API | Epi JS (served) | Views (inline) | C#-emitted JS | Vendor (served) |
|---|---|---|---|---|
| `$.browser` (removed 1.9) | – | – | – | maskedinput-1.3.js:8 (load-time), :369; bgiframe-2.1.2.js:9 (load-time); jquery.ui.core.js:80; jquery.ui.mouse.js:107; jquery.ui.dialog.js:802, 827; jquery.mobile-1.1.1.js:814 |
| `.live` / `.die` (removed 1.9) | – | Survey/Index.Mobile.cshtml:409 | – | validationEngine.js:27, 67–69 (live), 103–107 (die); jquery.mobile.simpledialog.min.js:8 |
| `.size()` (removed 3.0) | Print.js:5, 8 | – | – | validationEngine.js:615+; jquery-ui-1.8.16.custom.min.js ×5 |
| `.andSelf` / `$.curCSS` / `attrFn` / `$.event.handle` | – | – | – | jquery.ui.core.js:201 (andSelf), curCSS ×11 in UI 1.8.17 files incl. position.js:104+; UI 1.8.16 custom: curCSS ×19, andSelf ×6, attrFn ×1; dialog.js:42, 400 (attrFn); jquery.mobile-1.1.1.js:1795 (attrFn), :1807 (`$.event.handle`) |
| `$(window).load(fn)` (removed 3.0) | – | – | **AutoComplete.cs:282, Select.cs:259** (MobileAutoComplete.cs:286 is commented) | – |
| `.attr()`/`.removeAttr()` for checked/disabled/selected (semantics changed 1.9; use `.prop`) | CheckCodeEngineV1.js: 20 (checked ×5, disabled ×9, selected ×6; e.g. 649 `.attr("selected","Yes")`, 1167, 1306 `.attr('disabled', false)`, 1512, 1543); CheckCodeEngine.js: 19 | Account/Index.cshtml:13, 41; SurveyManager/Index.cshtml:280, 294, 436, 899, 901, 1104 | Hidden.cs:105, MirrorField.cs:102, MobileMirrorField.cs:89, MobileNumericTextBox.cs.cs:106 | – |
| `.bind` / `.delegate` (deprecated 3.0, still present in 3.7) | – | `.bind` ×6 (_Layout:121, _Layout.Mobile:33, 109, _LayoutPage2:98, …); `.delegate` ×11 (FormResponse/Index.Mobile:48, …) | – | jquery.mobile 107 bind; datebox 17 delegate, 13 bind; UI 1.8.16 76 bind |
| `$.parseJSON` (deprecated 3.0, removed 4.0) | – | ×6 (SurveyManager/Index:929, 940, 1208, 1211, …) | – | – |
| `$.trim` (deprecated 3.5) | – | Survey/Index:442, Survey/Index.Mobile:443 | – | – |
| positional `:first` etc. (deprecated 3.4) | Print.js:28 `body:first` | _Layout:94, _LayoutPage2:72, _LayoutPage3:77, Survey/Index:277 | – | – |
| `async:false` XHR (deprecated by browsers) | – | ×22 (FormResponse/Index.Mobile:136, …) | – | – |

**Fatal at page load if jQuery ≥1.9 is served:**

- **`_Layout` and `_LayoutPage2`:** maskedinput and bgiframe both use `$.browser` at load time.
- **`_Layout.Mobile`:** maskedinput uses `$.browser` at load time; JQM 1.1.1 hard-requires jQuery ≤1.7.1.

**I:** jQuery Migrate 1.x restores `$.browser`, `.live` and `.die`.

## 7. Security advisories for served and declared versions

Source: OSV (npm ecosystem). **V**

| Component | Served where | Advisories |
|---|---|---|
| jquery 1.6.3 / 1.7.1 | mobile, desktop, admin | CVE-2012-6708 [GHSA-2pqj-h3vj-pqgw](https://github.com/advisories/GHSA-2pqj-h3vj-pqgw), CVE-2015-9251 [GHSA-rmxg-73gg-4p98](https://github.com/advisories/GHSA-rmxg-73gg-4p98), CVE-2019-11358 [GHSA-6c3j-c64m-qhgq](https://github.com/advisories/GHSA-6c3j-c64m-qhgq), CVE-2020-7656 [GHSA-q4m3-2j7h-f7xw](https://github.com/advisories/GHSA-q4m3-2j7h-f7xw), CVE-2020-11023 [GHSA-jpcq-cgw6-v4j6](https://github.com/advisories/GHSA-jpcq-cgw6-v4j6) |
| jquery 1.12.4 (CDN) | report | CVE-2015-9251, CVE-2019-11358, CVE-2020-11022 [GHSA-gxr4-xjj5-5px2](https://github.com/advisories/GHSA-gxr4-xjj5-5px2), CVE-2020-11023 |
| jquery 3.5.0 (declared only) / 3.7.1 (target) | – | none |
| jquery-ui 1.8.16 / 1.8.17 | desktop, admin | CVE-2010-5312 [GHSA-wcm2-9c89-wmfm](https://github.com/advisories/GHSA-wcm2-9c89-wmfm), CVE-2012-6662 [GHSA-qqxp-xp9v-vvx6](https://github.com/advisories/GHSA-qqxp-xp9v-vvx6), CVE-2016-7103 [GHSA-hpcf-8vf9-q4gj](https://github.com/advisories/GHSA-hpcf-8vf9-q4gj), CVE-2021-41182 [GHSA-9gj3-hwp5-pmwc](https://github.com/advisories/GHSA-9gj3-hwp5-pmwc), CVE-2021-41183 [GHSA-j7qv-pgf6-hvh4](https://github.com/advisories/GHSA-j7qv-pgf6-hvh4), CVE-2021-41184 [GHSA-gpqq-952q-5327](https://github.com/advisories/GHSA-gpqq-952q-5327), CVE-2022-31160 [GHSA-h6gj-6jjq-h8g9](https://github.com/advisories/GHSA-h6gj-6jjq-h8g9) |
| jquery-ui 1.12.1 (CDN) | report | CVE-2021-41182/41183/41184, CVE-2022-31160; 1.14.1+ has none |
| jquery-mobile (all versions) | mobile | [GHSA-fj93-7wm4-8x2g](https://github.com/advisories/GHSA-fj93-7wm4-8x2g) XSS, **no fixed version** |
| bootstrap 4.2.1 | admin, report | CVE-2019-8331 [GHSA-9v3m-8fp8-mj99](https://github.com/advisories/GHSA-9v3m-8fp8-mj99) (tooltip/popover data-template XSS) |
| bootstrap 3.3.7 (on disk, unserved) | – | CVE-2016-10735, CVE-2018-14040, CVE-2018-14042, CVE-2018-20676, CVE-2018-20677, CVE-2019-8331, CVE-2024-6485 |
| bootstrap 3.4.1 (declared) | – | CVE-2024-6485 [GHSA-vxmc-5x29-h64v](https://github.com/advisories/GHSA-vxmc-5x29-h64v), CVE-2025-1647 [GHSA-q58r-hwc8-rm9j](https://github.com/advisories/GHSA-q58r-hwc8-rm9j); 5.3.8+ has none |
| jquery-validation 1.19.4 (declared, unserved) | – | CVE-2022-31147, CVE-2025-3573; 1.21.0+ has none |
| xlsx via unpinned unpkg (currently 0.18.5) | admin | CVE-2023-30533 [GHSA-4r6h-8v6p-xvw6](https://github.com/advisories/GHSA-4r6h-8v6p-xvw6), CVE-2024-22363 [GHSA-5pgg-2g8v-p4x9](https://github.com/advisories/GHSA-5pgg-2g8v-p4x9). Fixed builds are published only on the SheetJS CDN, not npm (**I**). |
| maskedinput, d3 5.8.2, c3 0.7.15, awesomplete, json2csv 5.0.7 | | no OSV entries found (absence ≠ safe) |

**Supply-chain risks:**

- **Unpinned CDN URLs.** The unpkg and jsDelivr URLs have no version pin and no SRI, so the code served can change without any repo change.
- **No SRI on code.jquery.com.** The code.jquery.com scripts have no SRI.

**Latest npm versions (2025, V):**

| Package | Latest |
|---|---|
| jquery | 4.1.0 |
| jquery-migrate | 4.0.2 |
| jquery-ui | 1.14.2 |
| bootstrap | 5.3.9 |
| jquery-validation | 1.22.1 |

The brief's target is jQuery **3.7.1**, paired with jQuery Migrate **3.x** (**I**).

## 8. Latent defects found (no change made)

1. **Bootstrap JS fails on SurveyManager.** The 4.2.1 jQuery-version guard throws on 1.7.1 (`_LayoutPage2.cshtml:40`). **I** (static)
2. **Duplicate jQuery on mobile.** `_Layout.Mobile.cshtml:20–21` loads 1.6.3, then 1.7.1. **V**
3. **Mixed jQuery UI 1.8.16 / 1.8.17** on `_Layout` and `_LayoutPage2`. **V**
4. **Mobile dialog and autocomplete probably fail** (§5). **I**
5. **Display-mode override ignored; probable null-UA crash; open redirect in an unreachable ViewSwitcher** (§5). **V**/**I**
6. **Missing files.** `PagerPartial` is missing **V**. The desktop `FormResponse/Index` view is missing, which probably causes a view-not-found error on desktop **I**.
7. **Manifests misreport what is served.** packages.config claims jQuery 3.5.0, Bootstrap 3.4.1 and Validation 1.19.4, none of which is on disk or served. **V**
8. **IE-era markup.** `X-UA-Compatible` meta; bgiframe (an IE6 shim); PIE.htc references, all commented out. **V**

## 9. Proposed migration sequence (gated)

**Every step:**

- **Rollback:** each step is a layout-scoped change, so rollback is a revert of that layout's file plus its assets. **V**
- **Gate:** no step starts until the test lane's seams for it are green against the *current* behavior.
- **Hosting:** a hosted app needs a test root `Web.config` (absent, per BUILDING.md), plus database and WCF service stand-ins or fakes.

| Step | Change | Tests required first (test lane) | Gate to proceed | Risks | Rollback |
|---|---|---|---|---|---|
| **a. Characterize** | No product change | S1–S9 (§10) | All seams pass on the baseline; browser checklist B1 recorded (manual if no host) | Hosting may be impossible short-term, so rely on static and controller seams plus a static harness | n/a |
| **b. One jQuery and one jQuery UI per layout** | Remove 1.6.3 from mobile. Use either the 1.8.16 full build or a single 1.8.17 set on `_Layout` and `_LayoutPage2`, keeping the full build because it serves datepicker/slider. Delete the bgiframe load. | S6 manifest snapshot updated; B1 survey entry, dates and dialogs | Snapshot diff equals intended removals; B1 unchanged | Subtle dialog differences between 1.8.16 and 1.8.17 | revert layout |
| **c. jQuery Migrate diagnostics** | Desktop/admin: move 1.7.1 → 1.12.4 + **Migrate 1.4.1** (development build, warnings logged). Mobile layout **stays on 1.7.1** because JQM 1.1.1 requires it. | S6; B1 run with the console captured; warning inventory | Zero *errors*; warnings catalogued per call site | maskedinput/bgiframe `$.browser` load failures (Migrate 1.x restores `$.browser`) | revert layout |
| **d. Replace plugins** | **Mobile (decision needed):** (1) responsive single layout (Bootstrap 5 or plain CSS) with native `<input type=date/time>`, dropping JQM, datebox and simpledialog and possibly display modes; (2) interim JQM 1.4.5 + datebox 4.x (still abandoned, still has the unfixed XSS); (3) keep JQM 1.1.1 isolated on 1.7.1 (status quo, accepts the risk). **Recommend (1).** **Desktop:** validationEngine → its current release or native/jquery-validation; maskedinput → maintained fork or native `pattern`; drop bgiframe; one idle-timeout library; replace jQuery Tools tooltip. **CheckCodeEngine:** abstract the date/checkbox/validation-prompt calls behind CCE_* adapters before swapping widgets. | S2, S3, S4, S5, S7; B1/B2 per field type; mobile device matrix (§5 table) | All field types render and check-code rules (hide/show/enable/disable/assign/goto/dialog) behave identically on both renderers | Largest change; mobile UX change; iPad behavior | per-layout flag (e.g. appSetting that selects the old or new layout) |
| **e. jQuery 3.7.1 + Migrate 3.x** | Fix Epi call sites from §6.2: `.attr`→`.prop`; `.live/.delegate/.bind`→`.on`; `$.parseJSON`→`JSON.parse`; `$(window).load`→`.on('load')` **in the C# emitters**; `.size()`→`.length`; `$.trim`→`String.prototype.trim`; positional selectors. Then remove Migrate once the warning count is 0. | S4 C#-emission assertions updated in the same PR; S5; B1/B2 with Migrate warnings at 0 | Migrate warnings 0; B1/B2 pass | Hidden `attr("checked")` semantics in check-code; emitter output changes need the S4 snapshot updated at the same time | revert, or restore Migrate |
| **f. jQuery UI 1.14.x, Bootstrap 5.3.x, CDN hygiene** | Upgrade jQuery UI (datepicker/dialog/autocomplete/slider) and timepicker. Bootstrap 4.2.1 → 5.3.x markup migration (data-bs-*, Popper bundle) in SurveyManager/Report. Localize code.jquery.com assets or add SRI. Pin xlsx (SheetJS CDN fixed build) and json2csv with SRI. Resolve the `$.fn.tooltip` collision. | S6; B3 SurveyManager/Report checklist (export to xlsx/csv, charts, modals) | B3 passes; no unpinned or SRI-less external script remains | Bootstrap markup churn; xlsx API changes | revert layout |
| **g. Remove dead assets, fix manifests** | Delete the orphans in §4.3, BundleConfig + Web.Optimization (or start rendering it), vsdoc/intellisense files and `packages/` remnants. Make packages.config truthful, or move client assets to LibMan/npm. Remove the IE-era meta/PIE. Fix or delete PagerPartial refs, EIWST/View.Mobile and the FormResponse desktop view. | S1, S6 (every referenced file exists; no unreferenced file under Scripts/Content) | S6 reports 0 missing and 0 orphaned | Something referenced dynamically (e.g. a config-driven URL) | git revert |

**Coupling and sequencing constraints:**

- **Mobile stays on 1.7.1 until JQM is replaced.** Step (c) is desktop/admin only.
- **Step (d) gates step (e) for the mobile layout.**
- **Step (b) can fix SurveyManager early.** Moving `_LayoutPage2` to 1.12.4 also unblocks its Bootstrap 4 JS, but that needs its own B3 check.
- **Pair with display-mode tests.** PRIORITIES.md item 3 also asks to confirm display-mode behavior first; S2 covers that.

## 10. Test seams requested from the test lane

| ID | Seam | Kind | Needs a host? |
|---|---|---|---|
| S1 | **Route table**: the routes in `RouteConfig` (no default and no ViewSwitcher route); the static-file ignore list | unit (RouteCollection + fake HttpContext) | no |
| S2 | **Display-mode selection**: for a UA matrix (null, empty, iPad legacy, iPadOS 13 desktop UA, Android phone, Android tablet, iPhone, Opera Mobi, desktop Chrome/Edge/Firefox), assert the selected `DisplayModeProvider` mode id; assert override-cookie behavior (currently ignored for the 3 custom modes) | unit (DisplayModeProvider + fake HttpContextBase) | no |
| S3 | **Layout resolution per action**: for each controller action, the view name returned and its effective layout under desktop and Mobile modes (including `View("Index")` on FormResponse with no desktop view) | controller tests + RazorViewEngine with a VirtualPathProvider over `Views/`, or a static parse of `Layout =` / `_ViewStart` | no (static) / partial |
| S4 | **Field-renderer emission**: `FormProvider` IsMobile/IsAndroid per UA; snapshot the HTML/JS emitted by each `Epi.DynamicForms.Core/Fields/*` renderer (desktop and Mobile*), including `$(window).load` and `.attr('disabled')` | unit | no |
| S5 | **Check-code JS emission**: snapshot `Rule_*.ToJavaScript` output for representative check-code (hide/unhide, enable/disable, assign, goto, dialog, date functions) to lock the `CCE_*` contract | unit | no |
| S6 | **Asset manifest**: parse every `.cshtml`; extract `<script src>`/`<link href>`/`Url.Content`; assert each local file exists; snapshot the ordered list per layout and view; list external URLs with pin/SRI flags; report orphaned files under Scripts/Content | static test (NUnit or script) | no |
| S7 | **JS unit harness** for `CheckCodeEngineV1.js`, `CheckCodeEngine.js`, `Print.js` and `jquery.Epi.Survey.Components.js` against fixture DOM, run with each candidate jQuery (1.7.1, 1.12.4+Migrate, 3.7.1+Migrate) and Migrate warnings collected | headless browser or jsdom static page | no ASP.NET host |
| S8 | **Static layout harness pages**: one HTML per layout loading its exact script stack (from S6) plus fixture form markup; assert no console errors at load and that the expected `$.fn.*` plugins are defined (would catch the Bootstrap guard and mobile `dialog`/`autocomplete` gaps) | headless browser | no ASP.NET host |
| S9 | **Hosted browser smoke** (B1 survey desktop: entry, validation, masks, date/time, dialogs, idle timeout, check-code; B2 survey mobile with the same items plus datebox and checkboxradio; B3 SurveyManager/Report: export, charts, modals, tooltips; plus a keyboard/a11y pass) | Playwright against IIS Express | **yes**: test root `Web.config`, DB/WCF fakes or a seeded environment |

The Web Survey NUnit baseline now covers custom display-mode selection and static layout asset order and existence (S2 and parts of S3/S6). It does not render Razor, run JavaScript, or cover the built-in mobile override in IIS; view-level and orphan inventory checks also remain. S7–S8 need only a headless browser and static files. S9 depends on resolving the absent root `Web.config` (BUILDING.md).

## 11. Unknowns

- **Real configuration:** the deployed `CUSTOM_THEME`, Omniture URLs and enablement, and whether a root `Web.config` in production registers extra modules or headers (e.g. CSP).
- **Unconfirmed runtime behavior:** all items marked **I** above, especially:
  - mobile layout resolution for explicit `Layout = "~/Views/Shared/_Layout.cshtml"`
  - the null-UA exception
  - iPhone browser-caps detection
  - mobile `.dialog("open")` and `.autocomplete` failures
- **Unversioned files:** jquery.numeric.js, awesomplete, mobileautocomplete.js, idle-timer.js and wordcloud2.js have no version headers.
- **Commit history unreviewed:** whether `Epi.Web_Bad.csproj` or `packages/` contents are used by any build or deploy script.
- **Unpinned CDN content:** xlsx and json2csv resolve to whatever the CDN serves on the day. The versions here were observed at the time of writing.
