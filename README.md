#### Run and investigate

##### Shell #1

```
$ export IMAGE_VIEWER=xviewer
$ make run
```
```
...
Check nodes: [{'slave3@127.0.0.1',false},
              {'slave8@127.0.0.1',false},
              {'slave2@127.0.0.1',false},
              {'slave9@127.0.0.1',false},
              {'slave1@127.0.0.1',false},
              {'slave6@127.0.0.1',
                  {'EXIT',
                      {timeout,{gen_server,call,[asg_manager,is_leader]}}}},
              {'slave4@127.0.0.1',false},
              {'slave7@127.0.0.1',false},
              {'slave10@127.0.0.1',true}]
Connect to master@127.0.0.1 and run:
test:graph().
test:restart(Node).
test:join(Node).
test:leave(Node).
test:ping_nodes(Node, Nodes).
test:is_leader(Node).
Run test:continue(). to proceed
```

##### Shell #2

```
$ erl -hidden -name adm$$@127.0.0.1 -remsh master@127.0.0.1

> test:graph().
> test:restart('slave1@127.0.0.1').
> test:graph().
> test:continue().
```

#### Run and auto-heal

##### Shell #1

```
$ export IMAGE_VIEWER=xviewer
$ make run-heal
```

##### Shell #2

```
$ erl -hidden -name adm$$@127.0.0.1 -remsh master@127.0.0.1

> test:pause().
> test:graph().
> test:continue().
```
