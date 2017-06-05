#!/usr/bin/python

# Docker Auto-Scaling Driver
# Version: 1.0
# Date: 2016-06-03

import sys
import os
import time
import re
import requests
import json

def debug(msg):
    if opts["verbose"] == "1":
        print "DEBUG: " + msg + "\n"

def getCCopts(opts):

    # Open and parse the credentials file
    ccFile = opts["ZH"] + "/zxtm/conf/cloudcredentials/" + opts["cloudcreds"]
    if os.path.exists(ccFile) is False:
        sys.stderr.write("ERROR - Cloud credentials file does not exist: " + ccFile + "\n")
        sys.exit(1)
    ccFH = open( ccFile, "r")
    for line in ccFH:
        kvp = re.search("(\w+)\s+(.*)", line.strip() )
        if kvp != None:
            opts[kvp.group(1)] = kvp.group(2)
    ccFH.close()

    # Check credential 1 is the config file
    if "cred1" in opts.keys():
        opts["cred1"] = opts["ZH"] + "/zxtm/conf/extra/" + opts["cred1"]
        if os.path.exists( opts["cred1"] ) is False:
            sys.stderr.write("ERROR - Docker config file is missing: " + opts["cred1"] + "\n")
            sys.exit(1)
    else:
        sys.stderr.write("ERROR - Credential 1 must be set to the Docker config file name\n")
        sys.exit(1)

    # Check credential 2 exists
    #if "cred2" not in opts.keys():
        #sys.stderr.write("ERROR - Credential 2 must be set to the Docker password\n")
        #sys.exit(1)
    
    # process the opsource configuration
    osFH = open( opts["cred1"], "r")
    for line in osFH:
        kvp = re.search("(\w+)\s+(.*)", line.strip() )
        if kvp != None:
            opts[kvp.group(1)] = kvp.group(2)
    osFH.close()

    if "apiHost" not in opts.keys():
        sys.stderr.write("ERROR - 'apiHost' must be specified in the Docker config file: " + opts["cred1"] + "\n")
        sys.exit(1)
    else:
        opts["url"] = opts["apiHost"] + "/v1.19"

    if opts["url"].startswith("https://"):
        if "ca" not in opts.keys():
            sys.stderr.write("ERROR - 'ca' must be specified when using https in config file: " + opts["cred1"] + "\n")
            sys.exit(1)
        if "keys" not in opts.keys():
            sys.stderr.write("ERROR - 'keys' must be specified when using https in config file: " + opts["cred1"] + "\n")
            sys.exit(1)

def newSession():
    client = requests.Session()
    if opts["url"].startswith("https://"):
        cas =  opts["ZH"] + "/zxtm/conf/ssl/cas/" + opts["ca"]
        clientCert = opts["ZH"] + "/zxtm/conf/ssl/client_keys/" + opts["keys"] + ".public"
        clientKey = opts["ZH"] + "/zxtm/conf/ssl/client_keys/" + opts["keys"] + ".private"
        debug("Using CA: " + cas)
        debug("Using Keys: " + clientCert + ", " + clientKey)
        client.verify=cas   
        client.cert=(clientCert, clientKey)
    return client
        
def getNodeStatus(filter, value):

    client = newSession()
    try:
        response = client.get( opts["url"] + "/containers/json?all=1" )
    except requests.RequestException as err:
        print "Error: Request Failed: " + str(err)
        sys.exit(1)

    debug ( response.text )

    nodes = []
    dHash = response.json()
    for server in dHash:
    
        id = server["Id"]
        if filter == "Id":
            if id != value:
                continue

        # Nodes created by us are labelled, so ignore hosts without a name label
        if "name" not in server["Labels"]:
            continue

        name = server["Labels"]["name"]
        if filter == "name":
            if name != value:
                continue

        config = client.get( opts["url"] + "/containers/" + id +"/json?all=1" )
        if config is None:
            continue
        config = config.json()

        imageID = server["Image"]
        state = server["Status"]
        created = config["Created"]
        privateIP = config["NetworkSettings"]["IPAddress"]
        publicIP = config["NetworkSettings"]["IPAddress"]

        status = "pending"
        complete = 50
        if state.startswith("Up"):
            complete = 100
            status = "active"
        elif state.startswith("Exited"):
            complete = 100
            status = "deleted"
        else:
            status = "pending"

        node = { "uniq_id": id, "name": name, "status": status, "private_ip": privateIP, 
            "public_ip": publicIP, "imageid": imageID, "complete": complete, "created": created,
            "sizeid": "custom" }
        nodes.append( node );

    return nodes


def getStatus():
    nodes = getNodeStatus("","")
    returnData = { "NodeStatusResponse": { "version": 1, "code": 200, "nodes": nodes } } 
    json.dump(returnData, sys.stdout )

def createNode():

    client = newSession()
    headers = { "Content-Type": "application/json" }

    payload = { "HostConfig": json.loads(opts["HostConfig"]), 
                "Image": opts["imageid"],
                "Labels": {"name": opts["name"]},
                "Env": [] }

    for env in opts.keys():
        if env.startswith("env_"):
            payload["Env"].append( env[4:] + "=" + opts[env] )

    debug( "SENDING -> " + json.dumps(payload) )

    try:
        response = client.post( opts["url"] + "/containers/create?name=" + opts["name"], data=json.dumps(payload), headers=headers )
    except requests.RequestException as err:
        print "Error: Request Failed: " + str(err)
        sys.exit(1)

    if ( response.status_code != 201 ):
        debug( "Failed to create container:" + response.text )
        return
    
    created = response.json()
    try:
        response = client.post( opts["url"] + "/containers/" + created["Id"] + "/start" )
    except requests.RequestException as err:
        print "Error: Request Failed: " + str(err)
        sys.exit(1)
    
    if ( response.status_code != 204 ):
        debug( "Failed to start container:" + response.text )
        return

    return created

def addNode():

    created = createNode()
    if created is not None:
        myNode = None
        loop = 0
        while myNode == None and loop < 3:
            node = getNodeStatus("Id",created["Id"])
            loop += 1
            if node is not None:
                debug("Found Node!")
                myNode = node[0]
                break
        debug("Sleeping...")
        time.sleep(2)
                
        myNode["sizeid"] = opts["sizeid"]    
        returnData = { "CreateNodeResponse": { "version": 1, "code": 202, "nodes": [ myNode ] }}
    else:
        returnData = { "CreateNodeResponse": { "version": 1, "code": 500, "nodes": [] }}
        
    json.dump(returnData, sys.stdout )


def delNode():
    
    client = newSession()

    try:
        response = client.post( opts["url"] + "/containers/" + opts["id"] + "/stop?t=5" )
        debug("Stop Container: " + response.text)
        response = client.delete( opts["url"] + "/containers/" + opts["id"] + "?v=1&force=1" )
        debug("Delete Container: " + response.text)

        if ( response.status_code != 204 ):
            debug("Failed to Delete Container: " + response.content)
            returnData = { "DestroyNodeResponse": { "version": 1, "code": 500, "nodes": [] }}
            json.dump(returnData, sys.stdout )
            sys.exit(1)

    except requests.RequestException as err:
        print "Error: Request Failed: " + str(err)
        sys.exit(1)

    returnData = { "DestroyNodeResponse": { "version": 1, "code": 202, "nodes": 
        [{ "created": 0, "uniq_id": opts['id'], "status": "destroyed", "complete": "100"}]}}
    
    json.dump(returnData, sys.stdout )


def help():
    sys.stderr.write("Usage: dockerScaler.py [--help] action options\n\n")
    sys.stderr.write("   action: [status|createnode|destroynode]\n\n")
    sys.stderr.write("   common options:\n")
    sys.stderr.write("      --verbose=1          Print verbose logging messages to the CLI\n")
    sys.stderr.write("      --cloudcreds=NAME    File in \$ZEUSHOME/zxtm/conf/cloudcredentials which stores the credentials\n\n")
    sys.stderr.write("   action-specific options (required):\n")
    sys.stderr.write("   createnode:\n")
    sys.stderr.write("      --name=NODENAME      Name to give newly created node\n")
    sys.stderr.write("      --imageid=IMAGEID    ID of the image to create a new instance of\n")
    sys.stderr.write("      --sizeid=SIZEID      ID of the server size/flavour to use\n")
    sys.stderr.write("   destroynode:\n")
    sys.stderr.write("      --id=SERVERID        ID of the server to destroy\n\n")
    sys.exit(1)

# Main block begin

# Check for ZEUSHOME and set up default options
opts = {"verbose": 0 }
opts["ZH"] = os.environ.get("ZEUSHOME")
if opts["ZH"] == None:
    if os.path.isdir("/usr/local/zeus"):
        opts["ZH"] = "/usr/local/zeus";
    elif os.path.isdir("/opt/zeus"):
        opts["ZH"] = "/opt/zeus";
    else:
        sys.stderr.write("ERROR - Can not find ZEUSHOME\n")
        sys.exit(1)

# Read in the first argument or display the help
if len(sys.argv) < 2:
    help()
else:
    action = sys.argv[1]

# Process additional arguments
for arg in sys.argv:
    kvp = re.search("--([^=]+)=(.*)", arg)
    if kvp != None:
        opts[kvp.group(1)] = kvp.group(2)

# We always need a cloudcreds... Check it here
if "cloudcreds" in opts.keys():
    getCCopts(opts)
    debug("CC options parsed. Connecting to " + opts["url"] )
else:
    sys.stderr.write("ERROR - You must provide a cloudcreds argument!")
    help()

# Check the action and call the appropriate function
if action.lower() == "help":
    help()
elif action.lower() == "status":
    getStatus()
elif action.lower() == "createnode":
    addNode()
elif action.lower() == "destroynode":
    delNode()
else:
    help()

