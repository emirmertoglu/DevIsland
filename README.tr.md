# Dev Island

[English](README.md) · **Türkçe**

Claude Code çalışırken seni haberdar eden yerel bir macOS menü çubuğu uygulaması. Birden fazla oturumu çentiğe uyumlu adadan takip et, dikkat gerektiğinde bildirim al ve ilgili terminale geri dön.

**Güncel sürüm: 0.4.1 — yerel alfa.** İmzalı dağıtım ve uçtan uca otomatik güncelleme için yayın kurulumu ve cihaz kabulü bekliyor. Tamamlanan kontroller ve kalan işler [doğrulama belgesinde](docs/VALIDATION.md).

## Özellikler

- **Çoklu oturum:** farklı proje ve terminallerde Claude oturum adları, kullanıcı etiketleri ve kalıcı bekleme durumları.
- **Bir bakışta durum:** soru, plan onayı, izin, yanıt tamamlanması, hata ve bağlantı kesilmesi.
- **Taşınabilir ada:** üst ortaya sabitle, özel konumu kaydet veya sabitli paneli açıp **Taşı** alanını sürükle. Tek tıklama adayı menü çubuğunun altına ayırır.
- **Animasyonlu karakterler:** Clawd, Kedi ve Robot; ada ve sürüklenebilir masaüstü maskotunda oturum durumlarını paylaşır. İki görünümü birlikte veya ayrı kullan.
- **Kişisel görünüm:** sistem/açık/koyu/siyah tema (siyah tema adayı çentikle bütünleştirir), değiştirilebilir vurgu ve karakter renkleri, ayrı sıfırlama düğmeleri, Liquid Glass, buzlu cam ve opak yüzeyler. Liquid Glass, macOS 14/15’te buzlu cam karşılığını kullanır.
- **Ayarlanabilir uyarılar:** olay bazında bildirim ve ses, özel ses düzeyi, sessiz saatler, erteleme ve oturum susturma.
- **Yerel erişilebilirlik:** Reduce Motion, Reduce Transparency, klavye kullanımı ve değiştirilebilir oturum kısayolu.
- **Türkçe ve İngilizce arayüz.**

## Gereksinimler

- **macOS 14 veya üzeri** çalıştıran Apple Silicon Mac.
- Oturum takibi için yerel olarak kurulu Claude Code.
- Derlemek için komut satırı araçları seçilmiş **Xcode 26 veya üzeri** ve Python 3. Kaynak kod Liquid Glass için macOS 26 SDK’sını kullanır; uygulama macOS 14+ hedefler.
- Derlemede sabitlenmiş **Sparkle 2.9.6** bağımlılığı SwiftPM ile indirilir. Bağlantı testleri için Node.js gerekir.

## Derleme ve bağlantı

Proje kök dizininde:

```bash
bash scripts/build-app.sh
open "dist/Dev Island.app"
```

Betik `dist/Dev Island.app` ve sürümlü ZIP üretir; güncel arşiv `dist/Dev-Island-0.4.1-arm64.zip` konumundadır. Yerel paket ad-hoc imzalıdır. Entegrasyonu kurmadan önce uygulamayı Applications’a taşı. Eski kopyayı değiştirirken **önce çalışan Dev Island’dan Çık**, ardından yeni kopyayı aç.

1. Ayarlar’da **Claude bağlantısı** bölümünü aç ve kurulumdan önce hook’ları incele. Mevcut Claude ayarları ve diğer hook’lar korunur; kurulum `settings.json` dosyasını yedekler.
2. İlk hook kurulumundan sonra mevcut Claude oturumlarını yeniden başlat; takip edildiğini doğrulamak için bir prompt gönder.
3. Sistem bildirimi istiyorsan **Bildirimler ve ses** bölümünden bildirim izni ver. Girişte başlatma isteğe bağlıdır ve varsayılan kapalıdır.
4. Doğru VS Code terminaline dönmek için **VS Code bağlantısını kur / güncelle** eylemini kullan. VSIX uygulamayla gelir. Bir pencere bağlanmazsa uygun zamanda yeniden yükle; mevcut terminaller yeniden oluşturulmaz.

## Günlük kullanım

Menü çubuğu simgesinden veya varsayılan **⇧⌘D** kısayolundan oturumları aç. Hover, uygulamayı öne almadan adayı açar; tıklayarak açılan liste kapatana kadar açık kalır. Escape paneli kapatır veya sürüklemeyi iptal eder.

Sabitliyken paneli aç ve menü çubuğunun altındaki **64×32 pt Taşı alanını** sürükle. Tek tıklama adayı kullanılabilir ekran alanına ayırır. Serbest başlıktaki pin düğmesi üst ortaya sabitler. Konum kaydedilir; ekranın altına yakınken panel yukarı açılabilir.

Uyarıyı kapatmak ya da susturmak bekleyen soruyu çözmez; Claude’un devam olayı gelmelidir. Yanıtın tamamlanması Claude’un turunun sona erdiğini belirtir; bütün projenin başarıyla bittiği anlamına gelmez. Masaüstü maskotu ek uyarı üretmez.

## Terminale geri dönüş

| Uygulama | Güncel davranış |
| --- | --- |
| VS Code | Birlikte gelen bağlantı eklentisiyle doğru yerel pencere ve terminali seçer; ad veya proje yolu tahmini yerine süreç kimliğini kullanır. |
| Apple Terminal | Automation izni varsa TTY ile eşleşen sekmeyi seçer; aksi durumda Terminal’i öne getirir. |
| Cursor / Warp | Kaynak uygulamayı öne getirir; tam terminal seçimi henüz desteklenmez. |

VS Code hedefi bulunamaz veya doğrulanamazsa yeni terminal açmak yerine hata gösterilir. SSH, uzak/dev-container terminalleri ve tmux paneli seçimi güncel kapsamın dışındadır. [Eklenti kurulumu](extensions/vscode/README.md) ve [yönlendirme ayrıntıları](docs/V036_VSCODE_ROUTING.md).

## Ses ve Focus

Dengeli profil soru, onay, izin ve hatada ses çalar; yanıt tamamlanması varsayılan sessizdir. Sistem bildirimleri ve sesleri macOS teslim ve Focus kurallarına tabidir. Özel sesin ayrı ses düzeyi vardır; özel ses ve ada otomatik olarak Focus’a uymaz. Sessiz mod, sessiz saatler ve oturum susturma bekleyen oturumları silmeden uyarıları kontrol eder.

## Gizlilik ve yerel veriler

Takip, Claude Code hook’ları ve küçük bir köprü üzerinden yerel çalışır. Hesap veya sunucu gerektirmez; telemetri eklenmez.

- Disk kuyruğu ve SwiftData geçmişi oturum metaverisini tutar; ham hook içeriği, prompt, komut, plan veya tam konuşma saklanmaz. Oturum adları Claude dosyaları değiştirilmeden yerel metaveriden okunur.
- Soru önizlemeleri bellekte kalır. Sistem bildirimleri genel durum metni kullanır.
- Veriler `~/Library/Application Support/DevIsland/` altında, tercihler UserDefaults’ta tutulur. Geçmiş varsayılan yedi gündür; aktif ve çözülmemiş oturumlar korunur.
- `CLAUDE_CONFIG_DIR` ve ayarlardaki dizin alanı özel Claude yapılandırmalarını destekler.
- Takip Ekran Kaydı, Accessibility veya Tam Disk Erişimi gerektirmez. Apple Terminal’de sekme seçimi Automation izni isteyebilir.

Entegrasyonu **Claude bağlantısı → Bağlantıyı kaldır** ile kaldırabilirsin. Diğer hook’lar korunur. Önceki hook komutlarını önbelleğe almış çalışan oturumların güvenli biçimde çıkabilmesi için köprü dosyası yerinde kalır.

## Güncelleme ve yayın

Sparkle, **Ayarlar → Güncellemeler** bölümünde saatlik kontrol, manuel kontrol ve isteğe bağlı beta sürümleri sunar. Kurulum kullanıcı eylemi gerektirir. Resmî paketler GitHub Releases, güncelleme akışı GitHub Pages üzerinden sunulur; oturum içeriği bu servislere gönderilmez.

**Yerel ad-hoc paketlerde uzaktan güncelleme kapalıdır.** Resmî yayın için Developer ID Application imzası, notarization, depo Secrets ve Pages kurulumu tamamlanmalıdır. Güncelleyici içeren ilk sürüm bir kez elle kurulur; sonraki resmî sürümler uygulama içinden güncellenebilir.

Sürüm ve build numarasının tek kaynağı [`Resources/version.json`](Resources/version.json) dosyasıdır. İmza, kararlı/beta etiketleri ve yayın iş akışı için [yayın kurulum rehberine](docs/UPDATES.md) bak.

## Geliştirme ve doğrulama

```bash
bash scripts/swift.sh test
node --test extensions/vscode/test/router.test.js
bash scripts/build-app.sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/smoke-bridge.py
python3 scripts/smoke-session-names.py
"dist/Dev Island.app/Contents/MacOS/DevIsland" --verify-storage
```

Yayın betiği testlerinden önce Sparkle imza araçlarının indirilmiş olması için derleme yap. Kayıtlı son doğrulamada **131 Swift testi başarılı, bir fiziksel ekran testi atlanmış; 11 bağlantı ve beş yayın testi başarılıdır**. Fiziksel mouse/trackpad, Spaces, çoklu ekran ve imzalı güncelleme kabulü ayrıca belgelenir; otomatik testler ve önizlemeler bu kontrollerin yerine geçmez.

Ayrı veri dizininde örnek oturumlar için önce çalışan uygulamadan çık:

```bash
open -n "dist/Dev Island.app" --args --demo --data-dir /tmp/dev-island-demo --show-settings
```

Demo modu hook kurmaz ve bildirim izni istemez. Yerleşim önizlemeleri üretmek için:

```bash
.build/arm64-apple-macosx/release/DevIsland --demo --data-dir /tmp/dev-island-render --render-preview previews
```

## Dokümanlar

- [Ürün ve mimari](docs/PLAN.md)
- [Yol haritası](docs/ROADMAP.md)
- [Doğrulama ve kalan kabul işleri](docs/VALIDATION.md)
- [Üste sabitli adayı taşıma](docs/V041_PINNED_DRAG.md)
- [Oturum adları](docs/V035_SESSION_NAMES.md)
- [Yayın ve güncelleme kurulumu](docs/UPDATES.md)
- [Görsel varlık bildirimleri](docs/ASSET_NOTICES.md) · [Sparkle lisansı](Resources/ThirdParty/Sparkle-LICENSE.txt)

Bazı teknik dokümanlar şu anda yalnızca Türkçedir.
