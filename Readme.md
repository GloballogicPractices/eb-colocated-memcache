## ElasticBeanstalk co-located memcache
### Motivation
* web applications that don't have connection pooling have often issues under high load  (risk of ddos-ing the backend during auto-scaling)
* ec2 instances offer quite lot of memory but limited bandwidth which becomes a bottleneck
* usable as application cache or http cache with nginx mmecached module
* deployed on an application which one page load makes cca 800 requests to memcache
* colocated memcache right alongside the application which reduces network latecy
* allows to prewarm the cache from a central memcache pool ( in this case Elasticache )

## Multi-Docker Elastic Beanstalk platform
* platform offers quite a flexibility
* enables to create "in application" aws resources

### The idea
Reduce network latency and provide a co-located cache for an application.

### The container
More info about McRouter 
https://github.com/facebook/mcrouter/wiki

This is a generic image that can be controlled by an environment variable. If McRouter is enabled, the memcached is shifted to a different port and the original port 11211 is used by mcrouter. The application then has to connect to the local McRouter.

```docker
FROM centos:latest
ENV             MCROUTER_DIR            /usr/local/mcrouter
ENV             MCROUTER_REPO           https://github.com/facebook/mcrouter.git
RUN yum -y update && yum -y install git memcached sudo && \
                mkdir -p $MCROUTER_DIR/repo && \
                cd $MCROUTER_DIR/repo && git clone $MCROUTER_REPO && \
                cd $MCROUTER_DIR/repo/mcrouter/mcrouter/scripts && \
                ./install_centos_7.2.sh $MCROUTER_DIR && \
                rm -rf $MCROUTER_DIR/repo && rm -rf $MCROUTER_DIR/pkgs && \
                ln -s $MCROUTER_DIR/install/bin/mcrouter /usr/local/bin/mcrouter && \
                yum -y clean all && yum -y erase "*-devel" && yum -y erase git

COPY docker-entrypoint.sh /
RUN mkdir -p /var/spool/mcrouter /var/mcrouter  && chown -R nobody:nobody /var/spool/mcrouter /var/mcrouter
USER nobody
ENTRYPOINT  ["/docker-entrypoint.sh"]
CMD memcached
EXPOSE 11211
EXPOSE 11212
```

```bash
#!/bin/sh
MEMCACHE_PORT=11211
if [ "X$MCROUTER_ENABLED" == "Xyes" ]; then
  /usr/local/bin/mcrouter -p 11211 --config file://usr/local/etc/mcrouter.conf &
  MEMCACHE_PORT=11212
fi
if [ "${1#-}" != "$1" ]; then
        set -- /usr/bin/memcached -p $MEMCACHE_PORT "$@"
fi
exec "$@"
```

### ElasticBeanstalk environment



```yaml
Resources:
  CacheSubnetGroup:
    Type: "AWS::ElastiCache::SubnetGroup"
    Properties:
      Description: "Cache group for EB Instances"
      SubnetIds:
        Fn::Split:
          - ","
          - Fn::GetOptionSetting:
              Namespace: aws:ec2:vpc
              OptionName: Subnets

  CacheSecurityGroup:
    Type: "AWS::EC2::SecurityGroup"
    Properties:
      GroupDescription: "Lock cache down to webserver access only"
      VpcId:
        Fn::GetOptionSetting:
          Namespace: "aws:ec2:vpc"
          OptionName: "VpcId"
      SecurityGroupIngress :
        - IpProtocol : "tcp"
          FromPort :
            Fn::GetOptionSetting:
              OptionName : "CachePort"
              DefaultValue: "11211"
          ToPort :
            Fn::GetOptionSetting:
              OptionName : "CachePort"
              DefaultValue: "11211"
          SourceSecurityGroupId:
            Fn::GetAtt: [ "AWSEBSecurityGroup", GroupId ]

  CachePeerInbound:
    Type: "AWS::EC2::SecurityGroupIngress"
    Properties:
      FromPort: 11211
      ToPort: 11212
      IpProtocol: "tcp"
      SourceSecurityGroupId:
        Fn::GetAtt: [ "AWSEBSecurityGroup", GroupId ]
      GroupId:
        Fn::GetAtt: [ "AWSEBSecurityGroup", GroupId ]

  ElastiCache:
    Type: "AWS::ElastiCache::CacheCluster"
    Properties:
      AZMode: "cross-az"
      CacheNodeType:
        Fn::GetOptionSetting:
          OptionName : "CacheNodeType"
          DefaultValue : "cache.t2.small"
      NumCacheNodes:
        Fn::GetOptionSetting:
          OptionName : "NumCacheNodes"
          DefaultValue : "2"
      Engine: "memcached"
      CacheSubnetGroupName:
        Ref: CacheSubnetGroup
      VpcSecurityGroupIds:
        - Fn::GetAtt: [ CacheSecurityGroup, GroupId ]

  MountTargetA:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: 
        Ref: FileSystem
      SecurityGroups:
        - Fn::GetAtt: [ MountTargetSecurityGroup, GroupId ]
      SubnetId:
        Fn::Select:
        - 0
        - Fn::Split:
          - ","
          - Fn::GetOptionSetting:
              Namespace: "aws:ec2:vpc"
              OptionName: Subnets

  MountTargetB:
    Type: AWS::EFS::MountTarget
    Properties:
      FileSystemId: 
        Ref: FileSystem
      SecurityGroups:
      - Ref: MountTargetSecurityGroup
      SubnetId:
        Fn::Select:
          - 1
          - Fn::Split:
              - ','
              - Fn::GetOptionSetting:
                  Namespace: "aws:ec2:vpc"
                  OptionName: Subnets

  FileSystem:
    Type: AWS::EFS::FileSystem
    Properties:
      PerformanceMode: generalPurpose
      FileSystemTags:
      - Key: Name
        Value:
          Fn::Join:
            - '-'
            - - Ref: AWSEBEnvironmentName
              - 'cache-config' 

  MountTargetSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for mount target
      SecurityGroupIngress:
      - FromPort: '2049'
        IpProtocol: tcp
        SourceSecurityGroupId:
          Fn::GetAtt: [ AWSEBSecurityGroup, GroupId ]
        ToPort: '2049'
      VpcId:
        Fn::GetOptionSetting: 
          Namespace: "aws:ec2:vpc"
          OptionName: VpcId
```

```yaml
files:
  /usr/local/bin/genmcrouter.sh:
    owner: root
    group: root
    mode: "000750"
    content: |
      #!/bin/bash -x
      export EB_ELB_NAME=`{ "Ref": "AWSEBLoadBalancer" }`
      export EB_MEMCACHE=`{ "Ref": "ElastiCache" }`
      export EB_ENVIRONMENT_NAME=`{ "Ref": "AWSEBEnvironmentName" }`
      { 
        aws ec2 describe-instances --instance-ids $( \
          aws elasticbeanstalk describe-environment-resources --environment-name $EB_ENVIRONMENT_NAME \
          --query 'EnvironmentResources.Instances[].Id | join(`\t`,@)' --output text ) && \
        aws elasticache describe-cache-clusters --cache-cluster-id $EB_MEMCACHE --show-cache-node-info;  
      } | jq --slurp -f /usr/local/etc/mcrouter.jq > /efs/mcrouter.conf
      rm -f /opt/elasticbeanstalk/hooks/appdeploy/post/99_genmcrouter.sh

  /usr/local/etc/mcrouter.jq:
    owner: root
    group: root
    mode: "000644"
    content: |
      {
        "pools": {
          "local": {
            "servers": [
                      "127.0.0.1:11212"
            ]
          },
          "peers": {
            "servers": [ 
              (.[].Reservations?|select( . != null )| .[].Instances[]| [ .PrivateIpAddress, "11212"] |join(":") ) 
            ]
          },
          "central": {
            "servers":  
              ([.[].CacheClusters?|select(. != null)| .[].CacheNodes[].Endpoint|[.Address,.Port|tostring]|join(":")]) 
          }
        },
        "route": {
          "type": "OperationSelectorRoute",
          "default_policy": "PoolRoute|central",
          "operation_policies": {
            "delete": {
              "type": "AllFastestRoute",
              "children": [
                "PoolRoute|peers",
                "PoolRoute|central"
              ]
            },
            "set": {
              "type": "AllFastestRoute",
              "children": [
                "PoolRoute|peers",
                "PoolRoute|central"
              ]
            },
            "get": {
              "type": "WarmUpRoute",
              "cold": "PoolRoute|local",
              "warm": "PoolRoute|central"
            }
          }
        }
      }

#commands:
#  01_post_appdeploy_dir:
#    command: mkdir -p /opt/elasticbeanstalk/hooks/appdeploy/post
#  02_link_mcrouter_script:
#    command: ln -s /usr/local/bin/genmcrouter.sh /opt/elasticbeanstalk/hooks/appdeploy/post/99_genmcrouter.sh
```

```
packages:
  yum:
    nfs-utils: []

files:
  /usr/local/bin/mount_shared_fs.sh:
    mode: '000700'
    owner: root
    group: root
    content: |
      #!/bin/sh
      MCROUTER_CONFIG_FS="`{"Ref": "FileSystem" }`.efs.`{"Ref" : "AWS::Region" }`.amazonaws.com"

      if [ ! -d /efs ]; then
        mkdir /efs
      fi
      RESTART_DOCKER_FLAG=0

      mountpoint -q /efs
      if [ $? -ne 0 ]; then
         mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2  $MCROUTER_CONFIG_FS:/ /efs
         RESTART_DOCKER_FLAG=1
      fi

      if [ $RESTART_DOCKER_FLAG -ne 0 ]; then
         service docker restart
         start ecs
         start eb-docker-events
         sleep 120
      fi

commands:
  01_mount_fs:
    command: /usr/local/bin/mount_shared_fs.sh
  02_mk_temporary_mcrouter:
    command: /usr/local/bin/genmcrouter.sh
  03_post_appdeploy_dir:
    command: mkdir -p /opt/elasticbeanstalk/hooks/appdeploy/post
  04_link_mcrouter_script:
    command: ln -s /usr/local/bin/genmcrouter.sh /opt/elasticbeanstalk/hooks/appdeploy/post/99_genmcrouter.sh
```

### Application

This is an example of an application using a colocated memcache on ElasticBeanstalk Multi container docker platform.

```
{
  "AWSEBDockerrunVersion": 2,
  "volumes": [
    {
      "name": "php-app",
      "host": {
        "sourcePath": "/var/app/current/app"
      }
    },
    {
      "name": "nginx-proxy-conf",
      "host": {
        "sourcePath": "/var/app/current/nginx"
      }
    },
    {
      "name": "nginx-logs",
      "host": {
         "sourcePath": "/var/log/nginx"
      }
    },
    {
      "name": "cache-config",
      "host": {
        "sourcePath": "/efs"
      }
    },
    { 
       "name": "haproxy-conf",
       "host": {
        "sourcePath": "/var/app/current/haproxy"
       }
    },
    {
       "name": "php-conf",
       "host": {
         "sourcePath": "/var/app/current/php"
       }
    }
  ],
  "containerDefinitions": [
    {
      "name": "engine-1",
      "image": "XXX.dkr.ecr.XXX.amazonaws.com/docker-php-fpm:X.X",
      "memoryReservation": 128,
      "essential": "true",
      "links" : [ "haproxy", "memcached" ],
      "mountPoints": [
        {
          "sourceVolume": "php-app",
          "containerPath": "/var/www/html"
        },
        {
          "sourceVolume" : "php-conf",
          "containerPath": "/usr/local/etc",
          "readOnly": true
        }
      ]
    },
    {
      "name": "nginx-proxy",
      "image": "XXX.dkr.ecr.XXX.amazonaws.com/nginx:X.X",
      "memoryReservation": 64,
      "essential": "true",
      "portMappings": [
        {
          "hostPort": 80,
          "containerPort": 80
        }
      ],
      "links": [
        "engine-1"
      ],
      "mountPoints": [
        {
          "sourceVolume": "php-app",
          "containerPath": "/var/www/html",
          "readOnly": true
        },
        {
          "sourceVolume": "nginx-proxy-conf",
          "containerPath": "/etc/nginx",
          "readOnly": true
        },
        {
          "sourceVolume": "nginx-logs",
          "containerPath": "/var/log/nginx"
        }
      ]
    },
    {
      "name": "haproxy",
      "image": "XXX.dkr.ecr.XXX.amazonaws.com/haproxy:1.6.X",
      "memoryReservation": 32,
      "essential": "false",
      "portMappings": [
        {
            "hostPort": 1936,
            "containerPort": 1936
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "haproxy-conf",
          "containerPath": "/usr/local/etc/haproxy",
          "readOnly": true
        }
      ]
    },
    {
      "name": "memcached",
      "image": "XXX.dkr.ecr.XXX.amazonaws.com/mcrouter-memcached:1.6.X",
      "memoryReservation": 1024,
      "essential": "true",
      "command": [ "-m", "1024" ],
      "environment": [
        {
           "name": "MCROUTER_ENABLED",
           "value": "yes"
        }
      ],
      "portMappings": [
        {
            "hostPort": 11211,
            "containerPort": 11211
        },
        {
            "hostPort": 11212,
            "containerPort": 11212
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "cache-config",
          "containerPath": "/usr/local/etc",
          "readOnly": true
        }
      ]

    }
  ]
}
```
