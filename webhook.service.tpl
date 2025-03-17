[Unit]
Description=DockerHub Webhook Server
After=network.target

[Service]
Environment=NODE_ENV=production
Environment=WEBHOOK_SECRET=${webhook_secret}
Type=simple
User=ec2-user
ExecStart=/usr/bin/node /home/ec2-user/webhook-server.js
Restart=on-failure

[Install]
WantedBy=multi-user.target 