# safepart

`safepart`, Linux sistemlerde disk, partition, filesystem, LVM, mount ve `fstab` işlemlerini daha güvenli şekilde yönetmek için hazırlanmış etkileşimli bir Bash aracıdır. Debian/Ubuntu, RHEL/Rocky/Alma/Fedora, SUSE/openSUSE ve Alpine ailelerindeki yaygın araç setlerini destekler.

Script; özellikle aşağıdaki işlerde yardımcı olur:

- Disk ve partition envanteri çıkarma
- Yeni partition oluşturma
- Bağımsız partition büyütme
- LVM zincir büyütme
- Partition tabanlı ve whole-disk LVM PV büyütme
- Hypervisor/SAN üzerinde önceden büyütülmüş PV alanını otomatik algılama
- Mount ve `fstab` yönetimi
- Disk ve partition sağlık özetleri alma
- Partition table yedekleme ve geri yükleme
- Dry-run doğrulama ve çok adımlı kullanıcı onayı

Bu araç doğrudan block device üzerinde çalıştığı için dikkatli kullanılmalıdır.

## Öne Çıkan Özellikler

- Etkileşimli menü desteği
- Non-interactive CLI desteği
- Kritik işlemler öncesi dry-run doğrulama
- Birçok adım için ayrı ayrı kullanıcı onayı
- Başlangıçta kritik araç kontrolü
- Eksik araç varsa otomatik kurulum teklifi
- Disk sağlık özeti
- Partition sağlık özeti
- `fstab` doğrulama ve güvenli ekleme/silme akışları
- Partition table ve LVM metadata yedekleme
- Güvenli loopback self-test laboratuvarı

## Desteklenen Yapılar

- Filesystem: `ext4`, `xfs`
- Partition table: `GPT`, `DOS/MBR`
- LVM: `PV`, `VG`, `LV`

## Bilinçli Sınırlar

- Otomatik partition create/grow yalnızca diskin sonundaki boş alanla çalışır.
- LVM PV bir partition veya doğrudan disk (`whole-disk PV`) olabilir.
- RAID, `mdadm`, `multipath`, `btrfs`, `zfs` ve karmaşık `crypt` topolojileri desteklenmez.
- Loopback selftest fiziksel diski birebir taklit etmez; temel block-device/filesystem/mount akışını güvenli biçimde doğrular.

## Başlangıç Davranışı

Script her açılışta:

1. Root yetkisini kontrol eder.
2. Gerekli dizinleri ve log hedeflerini hazırlar.
3. Kritik araçları kontrol eder.
4. Eksik kritik araç varsa kullanıcıya kurulum sorar.
5. Kullanıcı kabul etmezse normal akışa devam eder.
6. Ardından başlangıç sağlık kontrollerini çalıştırır.

## Gereksinimler

- Linux
- `bash`
- Root yetkisi

Script eksik araçları kendi içinde tespit edip kurulum önerebilir. Yine de tipik olarak şu paketler gerekir:

- `util-linux`
- `e2fsprogs`
- `xfsprogs`
- `lvm2`
- `gawk`
- `grep`
- `sed`
- `coreutils`
- `procps` veya `procps-ng`
- `mount`
- `psmisc`
- `smartmontools`

## Kurulum

Projeyi klonladıktan sonra scripti çalıştırılabilir yap:

```bash
chmod +x safepart.sh
```

Çalıştırma:

```bash
sudo ./safepart.sh
```

## Etkileşimli Kullanım

Script menü üzerinden şu temel işlemleri sunar:

- Araç kontrolü
- Gerekli araç kurulumu
- Disk/partition listesi
- Filesystem kullanım özeti
- Block device topolojisi
- Mount ve `fstab` özeti
- Disk sağlık özeti
- Partition sağlık özeti
- Loopback self-test laboratuvarı
- Partition table yedekleme / geri yükleme / reread
- Yeni partition oluşturma
- Bağımsız partition büyütme
- LVM tam zincir büyütme
- Unmount
- `fstab` kaydı silme
- Unmount + `fstab` temizleme

## CLI Kullanımı

Temel kullanım:

```bash
sudo ./safepart.sh [--dry-run] [--yes] [--help]
sudo ./safepart.sh --action <action> [opsiyonlar]
```

Global parametreler:

- `--dry-run`
- `--yes`
- `--help`

Desteklenen action değerleri:

- `create`
- `grow-part`
- `grow-lvm`
- `backup-pt`
- `restore-pt`
- `reread-pt`
- `unmount`
- `remove-fstab`
- `unmount-clean`
- `health-disk`
- `health-part`
- `selftest`

Opsiyonlar:

- `--disk /dev/sdX`
- `--target /dev/sdXN`
- `--target /dev/mapper/vg-lv`
- `--target /mountpoint`
- `--size-gb 100`
- `--fs ext4|xfs`
- `--mountpoint /data`
- `--structure normal|lvm` (`normal` = bağımsız partition)
- `--vg-name vg_data`
- `--lv-name lv_data`
- `--pv /dev/sda3` (çoklu-PV VG'lerde büyütülecek PV'yi seçer)
- `--backup-file /var/backups/safepart/<file>.sfdisk`

## CLI Örnekleri

Yeni bağımsız partition oluşturma:

```bash
sudo ./safepart.sh --action create \
  --disk /dev/sdb \
  --size-gb 100 \
  --fs ext4 \
  --mountpoint /data \
  --structure normal \
  --yes
```

Yeni LVM yapı oluşturma:

```bash
sudo ./safepart.sh --action create \
  --disk /dev/sdb \
  --size-gb 200 \
  --fs xfs \
  --mountpoint /srv/data \
  --structure lvm \
  --vg-name vg_data \
  --lv-name lv_app \
  --yes
```

Bağımsız partition büyütme:

```bash
sudo ./safepart.sh --action grow-part \
  --target /dev/sdb3 \
  --size-gb 300 \
  --yes
```

LVM büyütme:

```bash
sudo ./safepart.sh --action grow-lvm \
  --target /dev/mapper/vg_data-lv_app \
  --size-gb 500 \
  --yes
```

Bir VG içinde birden fazla PV varsa non-interactive kullanımda hedef PV açıkça belirtilmelidir:

```bash
sudo ./safepart.sh --action grow-lvm \
  --target /dev/mapper/rl-root \
  --pv /dev/sda3 \
  --size-gb 200 \
  --yes
```

Whole-disk PV örneği:

```bash
sudo ./safepart.sh --action grow-lvm \
  --target /dev/mapper/vg_data-lv_data \
  --pv /dev/sdb \
  --size-gb 800 \
  --yes
```

## Disk Büyütme Akışı

RHEL/Rocky Linux üzerinde tipik sıralama şöyledir:

1. Hypervisor, SAN veya bulut panelinde disk kapasitesi artırılır.
2. İşletim sisteminin yeni kapasiteyi gördüğü doğrulanır (`lsblk`, `blockdev --getsize64`).
3. Partition tabanlı PV ise partition büyütülür; GPT'nin eski secondary header bilgisi gerektiğinde `parted -f` ile düzeltilir.
4. Whole-disk PV veya önceden büyütülmüş partition üzerinde `pvresize` uygulanır.
5. LV ve ardından ext4/XFS filesystem büyütülür.

Script kernel yeni partition boyutunu gerçekten görmediyse filesystem veya PV büyütmeye devam etmez. Bu durumda güvenli biçimde durur ve reboot sonrasında işlemin yeniden çalıştırılmasını ister.

> “Unix tabanlı” kapsam burada Linux dağıtımlarını ifade eder. LVM2, `lsblk`, `partx` ve Linux block-device arayüzlerine dayandığı için macOS, FreeBSD, AIX, Solaris/illumos gibi farklı disk yönetim modelleri otomatik olarak desteklenmez.

Disk sağlık özeti:

```bash
sudo ./safepart.sh --action health-disk
```

Partition sağlık özeti:

```bash
sudo ./safepart.sh --action health-part
```

Loopback self-test:

```bash
sudo ./safepart.sh --action selftest
```

## Güvenlik Yaklaşımı

Script mümkün olduğunca güvenli davranacak şekilde tasarlanmıştır:

- Birçok destructive işlemden önce dry-run doğrulaması yapar.
- Kritik adımlarda kullanıcıdan tekrar onay ister.
- `fstab` güncellemelerinde doğrulama çalıştırır.
- Partition table işlemlerinde yedek almayı teşvik eder.
- LVM büyütme akışlarında aşamalı doğrulama uygular.

Buna rağmen bu araç gerçek diskler üzerinde değişiklik yapabilir. Özellikle üretim sistemlerinde kullanmadan önce:

- Güncel yedek alın
- Mümkünse test ortamında deneyin
- Hedef disk ve mountpoint bilgisini iki kez doğrulayın

## Sağlık Kontrolleri

### Disk Sağlığı

Disk sağlık ekranı şunları özetler:

- Disk boyutu ve model bilgisi
- Read-only durumu
- Döner disk / SSD ayrımı
- Device state
- `smartctl` varsa SMART sağlık verisi

### Partition Sağlığı

Partition sağlık ekranı şunlara bakar:

- Filesystem tipi
- Mountpoint ve mount seçenekleri
- `ro/rw` durumu
- Kullanım ve inode bilgisi
- Uygun durumlarda filesystem dry-run kontrolleri
- Kernel hata sinyalleri

## Loopback Self-Test Nedir?

Self-test laboratuvarı gerçek disklere dokunmadan geçici bir image dosyası oluşturur ve bunu loop device olarak bağlayarak temel akışları test eder.

Bu test tipik olarak şunları doğrular:

- Geçici image oluşturma
- Loop device attach
- Filesystem oluşturma
- Mount etme
- Test dosyası yazma
- `sync`
- Cleanup

Bazı sistemlerde loop device üzerinde gerçek partition table uygulaması uyumsuz davranabilir. Bu durumda selftest taşınabilir fallback modunda çalışır ve raw loop device üstünde filesystem/mount/yazma yolunu test eder.

## Unit Testleri (`tests/unit.sh`)

[`tests/unit.sh`](tests/unit.sh), disk büyütme mantığında daha önce düzeltilmiş hataların sonraki kod değişiklikleriyle yeniden oluşmasını önleyen hızlı regresyon testidir. Uygulamanın normal çalışması için zorunlu değildir; geliştirme ve katkı kontrolü amacıyla repoda tutulur.

Test sırasında gerçek disk, partition, LVM veya filesystem üzerinde işlem yapılmaz. `sfdisk`, `blockdev`, `lsblk` ve LVM sorguları kontrollü test fonksiyonlarıyla taklit edilir. Bu nedenle test root yetkisi istemez ve geliştirici bilgisayarında güvenle çalıştırılabilir.

Mevcut testler şunları doğrular:

- Büyütülmüş GPT diskte eski `last-lba` değerinin yeni kapasiteyi gizlememesi
- DOS/MBR yapısında 32-bit LBA sınırının aşılmaması
- Doğrudan diskin whole-disk LVM PV olarak seçilebilmesi
- Block device büyütüldüğünde LVM PV'nin henüz kullanmadığı alanın doğru hesaplanması

Testi repository kök dizininden çalıştırmak için:

```bash
bash tests/unit.sh
```

Başarılı çalışmada aşağıdakine benzer bir çıktı görülür:

```text
ok - GPT growth ignores stale last-lba
ok - MBR growth respects 32-bit LBA limit
ok - whole-disk PV is selectable
ok - expanded block device exposes unclaimed PV bytes
4 passed, 0 failed
```

Testin özellikle şu durumlarda çalıştırılması önerilir:

- `safepart.sh` içindeki disk, partition veya LVM fonksiyonları değiştirildiğinde
- Yeni Linux dağıtımı veya yeni disk topolojisi desteği eklendiğinde
- Commit ya da pull request göndermeden önce
- Bir disk büyütme hatası düzeltildikten sonra regresyon kontrolü için

Unit testleri yalnızca izole edilmiş karar ve hesaplama mantığını doğrular. Loop device üzerindeki bütünleşik akışı test etmek için ayrıca `sudo ./safepart.sh --action selftest` kullanılmalıdır. Üretim öncesinde ise hedef dağıtımla aynı yapıya sahip bir test VM'i üzerinde dry-run ve kabul testi yapılması önerilir.

## Log ve Yedek Dizinleri

Script aşağıdaki konumları kullanır:

- Log: `/var/log/safepart.log`
- Partition table yedekleri: `/var/backups/safepart`
- `fstab` yedekleri: `/var/backups/safepart/fstab`
- LVM metadata yedekleri: `/var/backups/safepart/lvm`

## Uyarı

Bu araç sistemin disk yapısını değiştirebilir. Yanlış kullanım veri kaybına yol açabilir. Kullanımdan önce hedef cihazı, mountpoint'i ve yapılacak işlemi dikkatle doğrulayın.
