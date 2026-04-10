# Disk Operations Tool

`Disk Operations Tool`, Linux sistemlerde disk, partition, filesystem, LVM, mount ve `fstab` işlemlerini daha güvenli şekilde yönetmek için hazırlanmış etkileşimli bir Bash aracıdır.

Script; özellikle aşağıdaki işlerde yardımcı olur:

- Disk ve partition envanteri çıkarma
- Yeni partition oluşturma
- Bağımsız partition büyütme
- LVM zincir büyütme
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
- LVM zincir büyütmede seçilen PV bir partition olmalıdır.
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
- `--backup-file /var/backups/disk-ops/<file>.sfdisk`

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

## Log ve Yedek Dizinleri

Script aşağıdaki konumları kullanır:

- Log: `/var/log/safepart.log`
- Partition table yedekleri: `/var/backups/disk-ops`
- `fstab` yedekleri: `/var/backups/disk-ops/fstab`
- LVM metadata yedekleri: `/var/backups/disk-ops/lvm`

## Uyarı

Bu araç sistemin disk yapısını değiştirebilir. Yanlış kullanım veri kaybına yol açabilir. Kullanımdan önce hedef cihazı, mountpoint'i ve yapılacak işlemi dikkatle doğrulayın.
