FROM node:20-alpine

WORKDIR /app

# Install MCP memory server and dependencies
RUN npm init -y && \
    npm install express cors @modelcontextprotocol/server-memory @modelcontextprotocol/sdk

# Create the proper MCP server
RUN cat > server.js << 'EOF'
const express = require('express');
const cors = require('cors');
const fs = require('fs');
const { spawn } = require('child_process');
const { EventEmitter } = require('events');

const app = express();
const PORT = process.env.PORT || 8081;
const MEMORY_FILE = process.env.MEMORY_FILE_PATH || '/app/data/memory.json';

app.use(cors());
app.use(express.json());

// Initialize memory file
const initMemory = () => {
  if (!fs.existsSync('/app/data')) {
    fs.mkdirSync('/app/data', { recursive: true });
  }
  if (!fs.existsSync(MEMORY_FILE)) {
    fs.writeFileSync(MEMORY_FILE, JSON.stringify({
      entities: [],
      relations: [],
      observations: []
    }, null, 2));
  }
};

// Health endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    timestamp: new Date().toISOString(),
    memoryFile: MEMORY_FILE,
    endpoints: { health: '/health', sse: '/sse', info: '/' }
  });
});

// Info endpoint
app.get('/', (req, res) => {
  res.json({
    name: 'MCP Memory Server',
    version: '1.0.0',
    transport: 'SSE',
    protocol: 'Model Context Protocol',
    endpoints: { health: '/health', sse: '/sse' },
    timestamp: new Date().toISOString()
  });
});

// SSE endpoint with full MCP protocol
app.get('/sse', (req, res) => {
  console.log('New MCP connection from:', req.ip);
  
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Cache-Control',
  });

  // Start the actual MCP memory server process
  const mcpServer = spawn('npx', ['@modelcontextprotocol/server-memory'], {
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { 
      ...process.env,
      MEMORY_FILE_PATH: MEMORY_FILE
    }
  });

  let messageId = 0;

  // Handle MCP server output
  mcpServer.stdout.on('data', (data) => {
    const output = data.toString();
    console.log('MCP Server output:', output);
    
    // Forward JSON-RPC messages to SSE client
    const lines = output.split('\n').filter(line => line.trim());
    lines.forEach(line => {
      try {
        const parsed = JSON.parse(line);
        res.write(`data: ${JSON.stringify(parsed)}\n\n`);
      } catch (e) {
        // Not JSON, might be logs
        console.log('MCP Server log:', line);
      }
    });
  });

  mcpServer.stderr.on('data', (data) => {
    console.error('MCP Server Error:', data.toString());
  });

  mcpServer.on('error', (error) => {
    console.error('Failed to start MCP server:', error);
    res.write(`data: ${JSON.stringify({error: 'Failed to start MCP server', details: error.message})}\n\n`);
  });

  // Send initialize message to MCP server
  const initializeMessage = {
    jsonrpc: '2.0',
    id: ++messageId,
    method: 'initialize',
    params: {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: {
        name: 'mcp-memory-remote',
        version: '1.0.0'
      }
    }
  };

  setTimeout(() => {
    mcpServer.stdin.write(JSON.stringify(initializeMessage) + '\n');
  }, 1000);

  // Handle client disconnect
  req.on('close', () => {
    console.log('Client disconnected, stopping MCP server');
    mcpServer.kill();
  });

  req.on('error', (err) => {
    console.error('SSE connection error:', err);
    mcpServer.kill();
  });

  // Keep connection alive
  const keepAlive = setInterval(() => {
    if (!res.destroyed) {
      res.write(': keepalive\n\n');
    }
  }, 30000);

  req.on('close', () => {
    clearInterval(keepAlive);
  });
});

// Handle POST requests for MCP commands (StreamableHTTP support)
app.post('/mcp', express.json(), (req, res) => {
  console.log('MCP StreamableHTTP request:', req.body);
  
  // This would be for the newer StreamableHTTP transport
  // For now, redirect to SSE
  res.json({
    error: 'Use SSE transport at /sse endpoint',
    transport: 'sse',
    endpoint: '/sse'
  });
});

// Initialize and start
initMemory();
app.listen(PORT, '0.0.0.0', () => {
  console.log(`MCP Memory Server running on port ${PORT}`);
  console.log(`Health: http://localhost:${PORT}/health`);
  console.log(`SSE: http://localhost:${PORT}/sse`);
  console.log(`Memory file: ${MEMORY_FILE}`);
});
EOF

# Create data directory
RUN mkdir -p /app/data

EXPOSE 8081
CMD ["node", "server.js"]
