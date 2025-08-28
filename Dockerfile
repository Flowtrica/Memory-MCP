FROM node:20-alpine

WORKDIR /app

# Install dependencies
RUN npm init -y && npm install express cors

# Create the server file directly in the image
RUN cat > server.js << 'EOF'
const express = require('express');
const cors = require('cors');
const fs = require('fs');

const app = express();
const PORT = process.env.PORT || 8081;

app.use(cors());
app.use(express.json());

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    timestamp: new Date().toISOString(),
    endpoints: {
      health: '/health',
      sse: '/sse',
      info: '/'
    }
  });
});

// Info endpoint  
app.get('/', (req, res) => {
  res.json({
    name: 'MCP Memory Server',
    endpoints: {
      health: '/health',
      sse: '/sse'
    },
    timestamp: new Date().toISOString()
  });
});

// SSE endpoint for MCP connections
app.get('/sse', (req, res) => {
  console.log('New SSE connection from:', req.ip);
  
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache', 
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Cache-Control'
  });

  // Send initial MCP message
  const initMessage = {
    jsonrpc: '2.0',
    method: 'notifications/initialized',
    params: {
      protocolVersion: '2025-06-18',
      capabilities: {
        tools: {},
        resources: {},
        prompts: {}
      },
      serverInfo: {
        name: 'mcp-memory-server',
        version: '1.0.0'
      }
    }
  };
  
  res.write(`data: ${JSON.stringify(initMessage)}\n\n`);

  // Keep connection alive with pings
  const pingInterval = setInterval(() => {
    res.write(`data: {"type":"ping","timestamp":"${new Date().toISOString()}"}\n\n`);
  }, 30000);

  // Handle disconnection
  req.on('close', () => {
    console.log('SSE connection closed');
    clearInterval(pingInterval);
  });

  req.on('error', (err) => {
    console.error('SSE connection error:', err);
    clearInterval(pingInterval);
  });
});

// Start the server
app.listen(PORT, '0.0.0.0', () => {
  console.log(`MCP Memory Server running on port ${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
  console.log(`SSE endpoint: http://localhost:${PORT}/sse`);
  console.log(`Info: http://localhost:${PORT}/`);
});
EOF

# Create data directory
RUN mkdir -p /app/data

# Expose port
EXPOSE 8081

# Run the server
CMD ["node", "server.js"]
