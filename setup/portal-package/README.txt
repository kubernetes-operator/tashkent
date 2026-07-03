# Model Factory Portal Scripts

Run order on Ubuntu server:

mkdir -p /ai/tashkent/setup
cp 05-portal.sh /ai/tashkent/setup/05-portal.sh
cp 06-worker-product-mode.sh /ai/tashkent/setup/06-worker-product-mode.sh
chmod +x /ai/tashkent/setup/05-portal.sh /ai/tashkent/setup/06-worker-product-mode.sh
/ai/tashkent/setup/05-portal.sh
/ai/tashkent/setup/06-worker-product-mode.sh
cd /ai/tashkent/3d-model-factory
./portal-local-test.sh

Portal URL:
http://<NODE_IP>:30083
