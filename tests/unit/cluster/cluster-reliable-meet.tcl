# make sure the test infra won't use SELECT
set old_singledb $::singledb
set ::singledb 1

tags {tls:skip external:skip cluster} {
    set base_conf [list cluster-enabled yes]
    start_multiple_servers 2 [list overrides $base_conf] {
        test "Cluster nodes are reachable" {
            for {set id 0} {$id < [llength $::servers]} {incr id} {
                # Every node should be reachable.
                wait_for_condition 1000 50 {
                    ([catch {R $id ping} ping_reply] == 0) &&
                    ($ping_reply eq {PONG})
                } else {
                    catch {R $id ping} err
                    fail "Node #$id keeps replying '$err' to PING."
                }
            }
        }

        test "Before slots allocation, all nodes report cluster failure" {
            wait_for_cluster_state fail
        }

        set CLUSTER_PACKET_TYPE_MEET 2
        set CLUSTER_PACKET_TYPE_NONE -1

        test "Cluster nodes haven't met each other" {
            assert {[llength [get_cluster_nodes 1]] == 1}
            assert {[llength [get_cluster_nodes 0]] == 1}
        }

        test "Allocate slots" {
            cluster_allocate_slots 2 0
        }

        test "MEET is reliable when target drops the initial MEETs" {
            # Make 0 drop the initial MEET messages due to link failure
            R 0 DEBUG DROP-CLUSTER-PACKET-FILTER $CLUSTER_PACKET_TYPE_MEET
            R 0 DEBUG CLOSE-CLUSTER-LINK-ON-PACKET-DROP 1

            R 1 CLUSTER MEET 127.0.0.1 [srv 0 port]

            # Wait for at least a few MEETs to be sent so that we are sure that 0 is
            # dropping them.
            wait_for_condition 1000 50 {
                [CI 0 cluster_stats_messages_meet_received] >= 3
            } else {
                fail "Cluster node 1 never sent multiple MEETs to 0"
            }

            # Make sure the nodes still don't know about each other
            # Using a wait condition here as an assert can be flaky - especially
            # when cluster nodes is processed when the link is established to send MEET.
            wait_for_condition 1000 50 {
                [llength [get_cluster_nodes 1 connected]] == 1
            } else {
                fail "Node 1 recognizes node 0 even though node 0 drops MEETs from node 1"
            }
            assert {[llength [get_cluster_nodes 0 connected]] == 1}

            R 0 DEBUG DROP-CLUSTER-PACKET-FILTER $CLUSTER_PACKET_TYPE_NONE

            # If the MEET is reliable, both a and b will turn to cluster state ok
            wait_for_condition 1000 50 {
                [CI 1 cluster_state] eq {ok} && [CI 0 cluster_state] eq {ok} &&
                [CI 0 cluster_stats_messages_meet_received] >= 4 &&
                [CI 1 cluster_stats_messages_meet_sent] == [CI 0 cluster_stats_messages_meet_received]
            } else {
                fail "1 cluster_state:[CI 1 cluster_state], 0 cluster_state: [CI 0 cluster_state]"
            }
        }
    } ;# stop servers
} ;# tags

set ::singledb $old_singledb

