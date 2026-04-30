module.exports = {
  apps: [
	{
	  name: "patet-api",
	  cwd: "/var/www/patet-api/current",
	  script: "dist/src/main.js",
	  interpreter: "node",
	  exec_mode: "cluster",
	  instances: 2,
	  autorestart: true,
	  max_restarts: 10,
	  restart_delay: 2000,
	  kill_timeout: 10000,
	  listen_timeout: 10000,
	  env: {
	    NODE_ENV: "production",
	  },
	},
    {
      name: "patet-website",
      cwd: "/var/www/patet-website/current",
      script: "./node_modules/next/dist/bin/next",
      args: ["start", "-p", "4993"],
      interpreter: "node",
      exec_mode: "cluster",
      instances: 2,
      autorestart: true,
      max_restarts: 10,
      restart_delay: 2000,
      kill_timeout: 10000,
      listen_timeout: 15000,
      wait_ready: false,
      env: {
        NODE_ENV: "production",
      },
    },
  ],
};
