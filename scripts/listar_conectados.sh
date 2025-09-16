#!/bin/bash
echo "status" | nc localhost 7505 | awk '/CLIENT LIST/,/ROUTING TABLE/' | head -n -1
