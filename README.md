# Oracle Cloud A1 Free Tier Catcher

A small Bash utility that automatically retries the creation of an Oracle Cloud `VM.Standard.A1.Flex` instance until capacity becomes available.

It is designed for situations where the Oracle Cloud Console repeatedly returns an error similar to:

```text
Out of capacity for shape VM.Standard.A1.Flex
```

Instead of manually clicking **Create** again and again, this script calls the OCI API periodically and stops as soon as an instance is successfully created.

## Features

* Automatic OCI capacity retries
* Multiple Availability Domains
* Tries `1 OCPU / 6 GB` first
* Then tries `2 OCPU / 12 GB`
* Automatic stop after successful creation
* Detects an already existing instance
* Handles temporary network and OCI service errors
* Timestamped logging
* Optional Telegram notifications
* Suitable for a local Linux machine or always-on Linux server

> This project is not affiliated with Oracle. Use it responsibly and respect Oracle Cloud limits and terms of service.

---

# How it works

The catcher follows this sequence:

```text
Check whether the instance already exists
            |
            v
Try 1 OCPU / 6 GB in AD-1
            |
            v
Try 1 OCPU / 6 GB in AD-2
            |
            v
Try 2 OCPU / 12 GB in AD-1
            |
            v
Try 2 OCPU / 12 GB in AD-2
            |
            v
Wait
            |
            v
Repeat
```

When OCI accepts one request:

```text
Instance created
      |
      v
Wait for RUNNING
      |
      v
Retrieve public IP
      |
      v
Send Telegram notification
      |
      v
Exit
```

---

# 1. Oracle Cloud preparation

Before using the script, prepare your Oracle Cloud account.

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

## 1.1 Create an OCI API signing key

Open the Oracle Cloud Console.

Go to:

```text
Profile
→ My Profile / User Settings
→ API Keys
→ Add API Key
```

You can either:

* let Oracle generate the API key pair, or
* upload your own RSA public key.

OCI API signing keys are RSA PEM keys. Oracle requires at least 2048-bit RSA keys.

If Oracle generates the key, download the private key and store it securely.

Never upload the private key to GitHub.

Oracle will display a configuration preview similar to:

```ini
[DEFAULT]
user=ocid1.user.oc1..example
fingerprint=aa:bb:cc:dd:ee:ff:...
tenancy=ocid1.tenancy.oc1..example
region=uk-london-1
key_file=/path/to/private/key.pem
```

Save these values.

## 1.2 Find your Tenancy OCID

In the OCI Console, open the tenancy information page.

Copy the value beginning with:

```text
ocid1.tenancy.oc1..
```

## 1.3 Find your User OCID

Open:

```text
Profile
→ User Settings
```

Copy the value beginning with:

```text
ocid1.user.oc1..
```

## 1.4 Find the Availability Domains

After configuring the OCI CLI, run:

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

Only add Availability Domains that work with your selected resources.

## 1.5 Find your subnet OCID

Run:

```bash
oci network subnet list \
  --compartment-id YOUR_COMPARTMENT_OCID \
  --all \
  --query 'data[].{"Name":"display-name","OCID":id}' \
  --output table
```

Copy the OCID of the subnet you want to use.

For a server requiring direct Internet access, this will usually be a public subnet.

## 1.6 Find an ARM-compatible image

Ampere A1 uses the ARM64/AArch64 architecture.

For Oracle Linux:

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

# 2. Linux installation

The recommended platform is Debian or Ubuntu.

## 2.1 Install prerequisites

```bash
sudo apt update
sudo apt install -y curl python3 python3-venv unzip git
```

## 2.2 Install OCI CLI

Run:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Reload your shell if required:

```bash
exec "$SHELL"
```

Verify:

```bash
oci --version
```

## 2.3 Configure OCI authentication

Create:

```text
~/.oci/config
```

Example:

```ini
[DEFAULT]
user=YOUR_USER_OCID
fingerprint=YOUR_API_KEY_FINGERPRINT
key_file=/home/YOUR_USER/.oci/oci_api_key.pem
tenancy=YOUR_TENANCY_OCID
region=YOUR_REGION
```

Protect the files:

```bash
chmod 600 ~/.oci/config
chmod 600 ~/.oci/oci_api_key.pem
```

Test OCI authentication:

```bash
oci iam region-subscription list --output table
```

A successful response should list your OCI region.

For unattended execution, use an API private key without an interactive passphrase.

---

# 3. Create the SSH key for the future VM

This is different from the OCI API signing key.

Create a dedicated SSH key:

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

Protect the private key:

```bash
chmod 600 ~/.ssh/oracle_a1
chmod 644 ~/.ssh/oracle_a1.pub
```

The public key will be injected into the newly created OCI instance.

The private key will later be used to connect:

```bash
ssh -i ~/.ssh/oracle_a1 opc@PUBLIC_IP
```

---

# 4. Install the catcher

Clone the repository:

```bash
git clone https://github.com/YOUR_USERNAME/oracle-a1-catcher.git
cd oracle-a1-catcher
```

Create your local configuration:

```bash
cp .env.example .env
```

Edit it:

```bash
nano .env
```

Fill in:

```bash
OCI_COMPARTMENT_ID="..."
OCI_SUBNET_ID="..."
OCI_IMAGE_ID="..."

OCI_AD_1="..."
OCI_AD_2="..."
```

Never commit `.env`.

Test the Bash syntax:

```bash
bash -n create-a1.example.sh
```

Make the script executable:

```bash
chmod +x create-a1.example.sh
```

Run:

```bash
./create-a1.example.sh
```

---

# 5. Windows

OCI CLI is also available for Windows.

Oracle provides both an MSI installer and a PowerShell installation method.

After installing OCI CLI, verify:

```powershell
oci --version
```

The OCI configuration directory is normally:

```text
%USERPROFILE%\.oci
```

and the configuration file is:

```text
%USERPROFILE%\.oci\config
```

The Bash catcher itself is designed primarily for Linux.

Windows users have three recommended options:

### WSL2

Install WSL2 with Ubuntu or Debian and follow the Linux instructions.

This is the recommended Windows method.

### Git Bash

The script may also work from Git Bash if all required Unix tools are available, but WSL2 provides a more predictable environment.

### Native PowerShell

A native PowerShell implementation can be created separately, but this repository currently focuses on Bash.

---

# 6. Run continuously with systemd

On Linux, the recommended method is a systemd service.

Example:

```ini
[Unit]
Description=Oracle Cloud A1 Catcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=YOUR_LINUX_USER
WorkingDirectory=/home/YOUR_LINUX_USER/oracle-a1-catcher
ExecStart=/home/YOUR_LINUX_USER/oracle-a1-catcher/create-a1.example.sh

Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
```

Install it:

```bash
sudo cp systemd/oracle-a1-catcher.service.example \
  /etc/systemd/system/oracle-a1-catcher.service
```

Edit the Linux username and path:

```bash
sudo nano /etc/systemd/system/oracle-a1-catcher.service
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable and start:

```bash
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

The computer must remain powered on and connected to the Internet.

---

# 7. Telegram notifications

Telegram notifications are optional.

They can notify you when:

* the catcher starts,
* it is still running after several hours,
* an unrecoverable error occurs,
* the OCI instance is successfully created.

## 7.1 Create a Telegram bot

Open Telegram and contact:

```text
@BotFather
```

Send:

```text
/newbot
```

Follow the instructions.

BotFather will provide a token similar to:

```text
123456789:AAxxxxxxxxxxxxxxxxxxxx
```

Treat this token like a password.

Never commit it to GitHub.

## 7.2 Start the bot

Open your new bot and send:

```text
/start
```

Then send any test message.

## 7.3 Find your Chat ID

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

## 7.4 Test notifications

```bash
curl -X POST \
  "https://api.telegram.org/botYOUR_TOKEN/sendMessage" \
  --data-urlencode "chat_id=YOUR_CHAT_ID" \
  --data-urlencode "text=Oracle A1 Catcher notification test"
```

If the message appears in Telegram, notifications are ready.

Add the values to your local `.env`:

```bash
TELEGRAM_BOT_TOKEN="YOUR_SECRET_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
```

Again: `.env` must never be committed.

---

# Security

Never commit:

```text
OCI private API keys
SSH private keys
Telegram bot tokens
.env
~/.oci/config
```

The repository `.gitignore` is intended to prevent accidental commits, but always verify before pushing:

```bash
git status
```

If a secret is accidentally committed, do not only delete the file. Revoke and regenerate the compromised credential.

---

# Logs

The catcher writes a log by default to:

```text
~/create-a1.log
```

Watch it live:

```bash
tail -f ~/create-a1.log
```

---

# Stopping the catcher

Interactive execution:

```text
Ctrl+C
```

systemd:

```bash
sudo systemctl stop oracle-a1-catcher.service
```

Disable automatic startup:

```bash
sudo systemctl disable --now oracle-a1-catcher.service
```

---

# Disclaimer

This script does not guarantee that Oracle Cloud capacity will become available.

Capacity depends entirely on Oracle Cloud infrastructure in the selected region and Availability Domain.

The script only automates repeated OCI API requests that could otherwise be performed manually from the Oracle Cloud Console.

Use sensible retry intervals and comply with Oracle Cloud terms, quotas and API limits.
