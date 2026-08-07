# Oracle A1 Free Tier Catcher

Automatically retries the creation of an Oracle Cloud `VM.Standard.A1.Flex` instance until capacity becomes available.

This project is useful when the Oracle Cloud Console repeatedly returns:

```text
Out of capacity for shape VM.Standard.A1.Flex
```

Instead of manually retrying from the web console, this script uses the OCI CLI to periodically attempt instance creation across multiple Availability Domains and configurations.

## Features

* Automatic retry loop
* Tries multiple Availability Domains
* Tries `1 OCPU / 6 GB` first, then `2 OCPU / 12 GB`
* Stops automatically after successful creation
* Detects an already existing instance
* Handles temporary OCI/network errors
* Timestamped logs
* Optional Telegram notifications
* Linux/systemd support
* Can also be used from Windows through WSL

> This project is not affiliated with Oracle.

---

# Repository structure

```text
oracle-a1-free-tier-catcher/
├── README.md
├── .gitignore
├── .env.example
├── create-a1.sh
└── systemd/
    └── oracle-a1-catcher.service.example
```

---

# 1. Oracle Cloud preparation

Before running the script, you need to collect several values from Oracle Cloud.

You will need:

* Tenancy OCID
* User OCID
* API signing key
* API key fingerprint
* Region
* Compartment OCID
* Subnet OCID
* ARM-compatible image OCID
* Availability Domain names

## 1.1 Find your Tenancy OCID

In the Oracle Cloud Console, open your tenancy details and copy the OCID.

It starts with:

```text
ocid1.tenancy.oc1..
```

## 1.2 Find your User OCID

Open:

```text
Profile
→ My profile
→ User information
```

Copy the value starting with:

```text
ocid1.user.oc1..
```

## 1.3 Create an API signing key

Go to:

```text
Profile
→ My profile
→ API keys
→ Add API key
```

You can either let Oracle generate the key pair or upload your own RSA public key.

Keep the private key secure.

Never commit the private key to GitHub.

After adding the key, Oracle displays a configuration preview similar to:

```ini
[DEFAULT]
user=ocid1.user.oc1..example
fingerprint=aa:bb:cc:dd:ee:ff:...
tenancy=ocid1.tenancy.oc1..example
region=uk-london-1
key_file=/path/to/private/key.pem
```

Save these values.

---

# 2. Install OCI CLI

## Linux / Debian / Ubuntu

Install prerequisites:

```bash
sudo apt update
sudo apt install -y curl python3 python3-venv unzip git
```

Install OCI CLI:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Reload your shell if needed:

```bash
exec "$SHELL"
```

Check:

```bash
oci --version
```

## Windows

The easiest method is WSL2.

Install WSL:

```powershell
wsl --install
```

Then install Debian or Ubuntu and follow the Linux instructions above.

Native Windows OCI CLI also works, but this Bash script is primarily designed for Linux.

---

# 3. Configure OCI authentication

Create the OCI configuration directory:

```bash
mkdir -p ~/.oci
```

Create:

```text
~/.oci/config
```

Example:

```ini
[DEFAULT]
user=YOUR_USER_OCID
fingerprint=YOUR_FINGERPRINT
key_file=/home/YOUR_USER/.oci/oci_api_key.pem
tenancy=YOUR_TENANCY_OCID
region=YOUR_REGION
```

Protect the files:

```bash
chmod 600 ~/.oci/config
chmod 600 ~/.oci/oci_api_key.pem
```

Test authentication:

```bash
oci iam region-subscription list --output table
```

A successful result should list your subscribed region.

---

# 4. Find your Availability Domains

Run:

```bash
oci iam availability-domain list \
  --compartment-id YOUR_TENANCY_OCID \
  --query 'data[].name' \
  --output table
```

Example:

```text
XXXX:UK-LONDON-1-AD-1
XXXX:UK-LONDON-1-AD-2
XXXX:UK-LONDON-1-AD-3
```

Only add the Availability Domains you want the script to try.

---

# 5. Find your subnet OCID

Run:

```bash
oci network subnet list \
  --compartment-id YOUR_COMPARTMENT_OCID \
  --all \
  --query 'data[].{"Name":"display-name","OCID":id}' \
  --output table
```

Choose the subnet you want to use.

If the future VM needs direct Internet access, use a public subnet.

---

# 6. Find an ARM-compatible image

Ampere A1 uses ARM64/AArch64.

Example for Oracle Linux:

```bash
oci compute image list \
  --compartment-id YOUR_COMPARTMENT_OCID \
  --operating-system "Oracle Linux" \
  --shape "VM.Standard.A1.Flex" \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --all \
  --query 'data[0].{"Name":"display-name","OCID":id}' \
  --output table
```

Copy the returned image OCID.

---

# 7. Create the SSH key for the future VM

This SSH key is different from the OCI API key.

Create it with:

```bash
mkdir -p ~/.ssh

ssh-keygen \
  -t rsa \
  -b 3072 \
  -f ~/.ssh/oracle_a1 \
  -N ""
```

You should now have:

```text
~/.ssh/oracle_a1
~/.ssh/oracle_a1.pub
```

Set permissions:

```bash
chmod 600 ~/.ssh/oracle_a1
chmod 644 ~/.ssh/oracle_a1.pub
```

The public key is injected into the OCI instance.

The private key is used later to connect:

```bash
ssh -i ~/.ssh/oracle_a1 opc@PUBLIC_IP
```

---

# 8. Clone the project

```bash
git clone https://github.com/alfawalidou/oracle-a1-free-tier-catcher.git
cd oracle-a1-free-tier-catcher
```

Create your local configuration:

```bash
cp .env.example .env
```

Edit it:

```bash
nano .env
```

Fill in your own values:

```bash
OCI_COMPARTMENT_ID="YOUR_COMPARTMENT_OCID"
OCI_SUBNET_ID="YOUR_SUBNET_OCID"
OCI_IMAGE_ID="YOUR_IMAGE_OCID"

OCI_AD_1="YOUR_PREFIX:YOUR_REGION-AD-1"
OCI_AD_2="YOUR_PREFIX:YOUR_REGION-AD-2"
```

Never commit `.env`.

---

# 9. Test the script

Check Bash syntax:

```bash
bash -n create-a1.sh
```

If there is no output, the syntax is valid.

Make it executable:

```bash
chmod +x create-a1.sh
```

Run:

```bash
./create-a1.sh
```

Example output:

```text
Trying AD-1 with 1 OCPU / 6 GB
No capacity available.

Trying AD-2 with 1 OCPU / 6 GB
No capacity available.

Trying AD-1 with 2 OCPU / 12 GB
No capacity available.
```

The script keeps retrying until OCI accepts one request.

---

# 10. Run continuously with systemd

A systemd example is included:

```text
systemd/oracle-a1-catcher.service.example
```

Copy it:

```bash
sudo cp systemd/oracle-a1-catcher.service.example \
  /etc/systemd/system/oracle-a1-catcher.service
```

Edit:

```bash
sudo nano /etc/systemd/system/oracle-a1-catcher.service
```

Replace:

```text
YOUR_LINUX_USER
```

with your Linux username and update the repository path.

Then run:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now oracle-a1-catcher.service
```

Check status:

```bash
sudo systemctl status oracle-a1-catcher.service
```

View logs:

```bash
sudo journalctl -u oracle-a1-catcher.service -f
```

The machine must remain powered on and connected to the Internet.

---

# 11. Telegram notifications

Telegram notifications are optional.

They can notify you when:

* the catcher starts
* it is still running after several hours
* a fatal error occurs
* the VM is successfully created

## 11.1 Create a bot

Open Telegram and contact:

```text
@BotFather
```

Send:

```text
/newbot
```

Follow the instructions.

BotFather gives you a token similar to:

```text
123456789:AAxxxxxxxxxxxxxxxxxxxx
```

Keep this token secret.

## 11.2 Start your bot

Open the bot and send:

```text
/start
```

Then send any message such as:

```text
test
```

## 11.3 Find your Chat ID

Run:

```bash
curl -s \
  "https://api.telegram.org/botYOUR_TOKEN/getUpdates"
```

Look for:

```json
"chat": {
  "id": 123456789
}
```

The number is your Telegram Chat ID.

## 11.4 Test the bot

```bash
curl -X POST \
  "https://api.telegram.org/botYOUR_TOKEN/sendMessage" \
  --data-urlencode "chat_id=YOUR_CHAT_ID" \
  --data-urlencode "text=Oracle A1 Catcher test"
```

If the message arrives, add both values to `.env`:

```bash
TELEGRAM_BOT_TOKEN="YOUR_SECRET_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
```

---

# 12. Logs

The script writes logs to:

```text
~/create-a1.log
```

Watch them live:

```bash
tail -f ~/create-a1.log
```

---

# 13. Troubleshooting

## Out of capacity

Example:

```text
Out of capacity for shape VM.Standard.A1.Flex
```

This is the expected condition.

The script waits and retries.

## NotAuthenticated

Example:

```text
401 NotAuthenticated
```

Check:

* User OCID
* Tenancy OCID
* API key fingerprint
* private key path
* OCI API key registration

## Request timeout

Example:

```text
The connection to endpoint timed out
```

The script treats this as a temporary network error and retries automatically.

## NotAuthorizedOrNotFound

This can indicate:

* wrong Availability Domain
* unavailable resource in that AD
* wrong subnet/image OCID
* missing permission

Remove any Availability Domain that consistently returns this error.

---

# Security

Never commit:

```text
.env
OCI private API keys
SSH private keys
Telegram bot tokens
~/.oci/config
```

Always check before pushing:

```bash
git status
```

If a secret is accidentally committed, revoke and regenerate it.

---

# Disclaimer

This script does not guarantee that Oracle Cloud capacity will become available.

Capacity depends entirely on Oracle Cloud infrastructure in the selected region.

Use reasonable retry intervals and respect Oracle Cloud quotas, rate limits and terms of service.
