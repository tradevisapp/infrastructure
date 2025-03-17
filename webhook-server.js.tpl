const http = require('http');
const { exec } = require('child_process');

const PORT = 9000;
const SECRET = process.env.WEBHOOK_SECRET || 'your-webhook-secret';

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/webhook') {
    let body = '';
    
    req.on('data', chunk => {
      body += chunk.toString();
    });
    
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        
        // Verify it's from DockerHub
        if (payload.push_data && payload.repository) {
          console.log(`Received webhook for $${payload.repository.name}:$${payload.push_data.tag}`);
          
          // Pull the latest image and restart the container
          exec('cd /home/ec2-user && docker-compose pull frontend && docker-compose up -d', 
            (error, stdout, stderr) => {
              if (error) {
                console.error(`Error: $${error.message}`);
                return;
              }
              if (stderr) {
                console.error(`stderr: $${stderr}`);
              }
              console.log(`stdout: $${stdout}`);
              console.log('Container updated successfully');
            }
          );
          
          res.statusCode = 200;
          res.end('Webhook received and processing');
        } else {
          res.statusCode = 400;
          res.end('Invalid webhook payload');
        }
      } catch (error) {
        console.error('Error processing webhook:', error);
        res.statusCode = 400;
        res.end('Error processing webhook');
      }
    });
  } else {
    res.statusCode = 404;
    res.end('Not found');
  }
});

server.listen(PORT, () => {
  console.log(`Webhook server running on port $${PORT}`);
}); 