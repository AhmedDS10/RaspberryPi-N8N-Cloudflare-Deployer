لتثبيت **Docker** و **Portainer** على **Raspberry Pi OS (الإصدار الأحدث)**، اتبع الخطوات التالية:

---

### **الخطوة 1: تحديث النظام**
أولًا، قم بتحديث الحزم المثبتة على Raspberry Pi:
```sh
sudo apt update && sudo apt upgrade -y
```

---

### **الخطوة 2: تثبيت Docker**
1. قم بتثبيت المتطلبات الأساسية:
   ```sh
   sudo apt install -y ca-certificates curl gnupg
   ```
2. أضف مفتاح توقيع Docker الرسمي:
   ```sh
   sudo install -m 0755 -d /etc/apt/keyrings
   curl -fsSL https://download.docker.com/linux/debian/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
   sudo chmod a+r /etc/apt/keyrings/docker.asc
   ```
3. أضف مستودع Docker الرسمي:
   ```sh
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
   ```
4. تحديث قائمة الحزم وتثبيت Docker:
   ```sh
   sudo apt update
   sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```

5. تحقق من تثبيت Docker:
   ```sh
   sudo systemctl enable --now docker
   sudo docker --version
   ```

6. أضف المستخدم إلى مجموعة `docker` (اختياري لتشغيل Docker بدون `sudo`):
   ```sh
   sudo usermod -aG docker $USER
   ```
   بعد ذلك، أعد تشغيل الجهاز أو قم بتسجيل الخروج ثم تسجيل الدخول مجددًا.

---

### **الخطوة 3: تثبيت Portainer**
1. قم بإنشاء مجلد لحفظ بيانات Portainer:
   ```sh
   sudo mkdir -p /data/portainer
   ```
2. قم بتنزيل وتشغيل Portainer:
   ```sh
   sudo docker run -d \
     --name portainer \
     --restart=always \
     -p 8000:8000 -p 9443:9443 \
     -v /var/run/docker.sock:/var/run/docker.sock \
     -v /data/portainer:/data \
     portainer/portainer-ce:latest
   ```
3. تحقق من تشغيل الحاوية:
   ```sh
   sudo docker ps
   ```

---

### **الخطوة 4: الوصول إلى Portainer**
- افتح متصفح الويب وانتقل إلى:
  ```
  https://<Raspberry_Pi_IP>:9443
  ```
- ستظهر لك صفحة إعداد Portainer لإنشاء حساب المسؤول.

**مبروك! 🎉 أصبح لديك الآن Docker و Portainer يعملان على Raspberry Pi.** 🚀

لتحويل ملف `docker-compose.yml` إلى أوامر `docker run`، سنحتاج إلى تحويل كل خدمة (`postgres` و `n8n`) إلى أمر `docker run` مع المعاملات المطلوبة. إليك كيفية فعل ذلك:

### 1. **خدمة PostgreSQL:**

```bash
docker run -d \
  --name postgres \
  --restart always \
  -e POSTGRES_USER=${db_user} \
  -e POSTGRES_PASSWORD=${db_password} \
  -e POSTGRES_DB=n8n \
  -e TZ=Asia/Baghdad \
  -v postgres_data:/var/lib/postgresql/data \
  postgres:15.8
```

### 2. **خدمة n8n:**

```bash
docker run -d \
  --name n8n \
  --user "root" \
  --restart always \
  -p 8443:5678 \
  -e N8N_HOST=localhost \
  -e N8N_PORT=5678 \
  -e N8N_PROTOCOL=http \
  -e NODE_ENV=production \
  -e N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true \
  -e WEBHOOK_URL=https://${domain_name} \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=postgres \
  -e DB_POSTGRESDB_PORT=5432 \
  -e DB_POSTGRESDB_DATABASE=n8n \
  -e DB_POSTGRESDB_USER=${db_user} \
  -e DB_POSTGRESDB_PASSWORD=${db_password} \
  -e TZ=Asia/Baghdad \
  -v ~/.n8n:/home/node/.n8n \
  --link postgres:postgres \
  n8nio/n8n
```

### التفسير:

- **`docker run -d`**: لتشغيل الحاوية في الخلفية.
- **`--name`**: لتسمية الحاوية.
- **`--restart always`**: لضمان إعادة تشغيل الحاوية تلقائيًا في حال توقفها.
- **`-e`**: لتحديد متغيرات البيئة.
- **`-v`**: لتعريف المجلدات المشتركة (المجلدات التي يتم حفظ البيانات فيها بين الحاويات والمضيف).
- **`--link postgres:postgres`**: للربط بين حاوية `n8n` و `postgres` عبر اسم الحاوية. يمكن أن يساعد ذلك في الوصول إلى قاعدة البيانات.

### ملاحظة:
- تأكد من استبدال `${db_user}`, `${db_password}`, و `${domain_name}` بالقيم الفعلية التي تستخدمها.

### Manual Installation

1. Download the installation script
```bash
wget -O install-n8n.sh https://raw.githubusercontent.com/xshocuspocusxd/RaspberryPi-N8N-Cloudflare-Deployer/refs/heads/main/rpi-n8n-cloudflare-installer.sh
```

2. Make it executable
```bash
nano install-n8n.sh
chmod +x install-n8n.sh
```

3. Run the script
```bash
./install-n8n.sh
```
