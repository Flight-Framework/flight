import Foundation
import Testing
import FlightPubSub

@Suite("LocalPubSub — the in-process core", .timeLimit(.minutes(1)))
struct LocalPubSubTests {

    // MARK: - Delivery

    @Test("subscribe then publish delivers — registration is effective at return")
    func subscribeThenPublish() async {
        let pubsub = LocalPubSub()
        var iterator = pubsub.subscribe("room:1").makeAsyncIterator()
        await pubsub.publish(msg("room:1", "hello"))
        let received = await iterator.next()
        #expect(received.map(text) == "hello")
    }

    @Test("fan-out: every subscriber of the topic receives the message")
    func fanOut() async {
        let pubsub = LocalPubSub()
        var iterators = (0..<3).map { _ in pubsub.subscribe("room:1").makeAsyncIterator() }
        await pubsub.publish(msg("room:1", "to-everyone"))
        for index in iterators.indices {
            let received = await iterators[index].next()
            #expect(received.map(text) == "to-everyone")
        }
    }

    @Test("exact-match topic isolation: other topics receive nothing")
    func topicIsolation() async {
        let pubsub = LocalPubSub()
        var roomA = pubsub.subscribe("room:a").makeAsyncIterator()
        var roomB = pubsub.subscribe("room:b").makeAsyncIterator()
        await pubsub.publish(msg("room:b", "for-b"))
        await pubsub.publish(msg("room:a", "for-a"))
        // A's FIRST message is the a-message: the b-publish never reached it.
        let receivedA = await roomA.next()
        #expect(receivedA.map(text) == "for-a")
        let receivedB = await roomB.next()
        #expect(receivedB.map(text) == "for-b")
    }

    @Test("no replay: a message published before subscribing is never seen")
    func noReplay() async {
        let pubsub = LocalPubSub()
        await pubsub.publish(msg("room:1", "too-early"))
        var iterator = pubsub.subscribe("room:1").makeAsyncIterator()
        await pubsub.publish(msg("room:1", "on-time"))
        let received = await iterator.next()
        #expect(received.map(text) == "on-time")
    }

    @Test("publish with no subscribers is a harmless no-op")
    func publishToNobody() async {
        let pubsub = LocalPubSub()
        await pubsub.publish(msg("empty", "void"))
        #expect(pubsub.subscriberCount(for: "empty") == 0)
    }

    @Test("payload and metadata arrive intact")
    func integrity() async {
        let pubsub = LocalPubSub()
        var iterator = pubsub.subscribe("t").makeAsyncIterator()
        let original = Message(
            topic: "t",
            payload: Data((0...255).map { UInt8($0) }),
            metadata: ["a": "1", "b": "2"]
        )
        await pubsub.publish(original)
        let received = await iterator.next()
        #expect(received == original)
    }

    // MARK: - Ordering

    @Test("per-subscriber publish order is preserved")
    func ordering() async {
        let pubsub = LocalPubSub()
        var iterator = pubsub.subscribe("seq").makeAsyncIterator()
        for i in 0..<200 {
            await pubsub.publish(msg("seq", "\(i)"))
        }
        for i in 0..<200 {
            let received = await iterator.next()
            #expect(received.map(text) == "\(i)")
        }
    }

    // MARK: - Back-pressure isolation

    @Test("a slow subscriber blocks neither the publisher nor other subscribers")
    func slowSubscriberIsolation() async {
        let pubsub = LocalPubSub()
        let slow = pubsub.subscribe("busy")  // never consumed while publishing
        var fast = pubsub.subscribe("busy").makeAsyncIterator()

        for i in 0..<100 {
            await pubsub.publish(msg("busy", "\(i)"))  // returns regardless of `slow`
        }
        for i in 0..<100 {
            let received = await fast.next()
            #expect(received.map(text) == "\(i)")
        }
        // The slow subscriber's backlog is its own: all 100 buffered, in order.
        var slowIterator = slow.makeAsyncIterator()
        for i in 0..<100 {
            let received = await slowIterator.next()
            #expect(received.map(text) == "\(i)")
        }
    }

    @Test("bounded .bufferingOldest policy keeps the first N, drops the rest")
    func bufferingOldest() async {
        let pubsub = LocalPubSub(bufferingPolicy: .bufferingOldest(5))
        var iterator = pubsub.subscribe("bounded").makeAsyncIterator()
        for i in 0..<10 {
            await pubsub.publish(msg("bounded", "\(i)"))
        }
        for i in 0..<5 {
            let received = await iterator.next()
            #expect(received.map(text) == "\(i)")
        }
    }

    @Test("bounded .bufferingNewest policy keeps the latest N")
    func bufferingNewest() async {
        let pubsub = LocalPubSub(bufferingPolicy: .bufferingNewest(5))
        var iterator = pubsub.subscribe("bounded").makeAsyncIterator()
        for i in 0..<10 {
            await pubsub.publish(msg("bounded", "\(i)"))
        }
        for i in 5..<10 {
            let received = await iterator.next()
            #expect(received.map(text) == "\(i)")
        }
    }

    // MARK: - Subscription lifetime

    @Test("cancelling the consuming task tears the subscription down")
    func cancellationUnsubscribes() async {
        let pubsub = LocalPubSub()
        let stream = pubsub.subscribe("room:1")
        #expect(pubsub.subscriberCount(for: "room:1") == 1)

        let consumer = Task {
            for await _ in stream {}
        }
        consumer.cancel()
        await consumer.value
        #expect(pubsub.subscriberCount(for: "room:1") == 0)
        #expect(pubsub.activeTopicCount == 0)
    }

    @Test("breaking out of iteration and dropping the stream tears the subscription down")
    func breakUnsubscribes() async {
        let pubsub = LocalPubSub()

        func subscribeAndTakeOne() async -> String? {
            let stream = pubsub.subscribe("room:1")
            await pubsub.publish(msg("room:1", "first"))
            for await message in stream {
                return text(message)  // stream dropped at function exit
            }
            return nil
        }

        let first = await subscribeAndTakeOne()
        #expect(first == "first")
        // Deinit-triggered termination is prompt but its completion relative
        // to the caller resuming isn't specified — poll briefly.
        #expect(await eventually { pubsub.subscriberCount(for: "room:1") == 0 })
        #expect(await eventually { pubsub.activeTopicCount == 0 })
    }

    @Test("a subscriber that leaves stops receiving; remaining subscribers are unaffected")
    func departureLeavesOthersIntact() async {
        let pubsub = LocalPubSub()
        let leaver = pubsub.subscribe("room:1")
        var stayer = pubsub.subscribe("room:1").makeAsyncIterator()

        let leavingConsumer = Task { for await _ in leaver {} }
        leavingConsumer.cancel()
        await leavingConsumer.value
        #expect(pubsub.subscriberCount(for: "room:1") == 1)

        await pubsub.publish(msg("room:1", "still-flowing"))
        let received = await stayer.next()
        #expect(received.map(text) == "still-flowing")
    }

    @Test("topic registry entries are removed when the last subscriber leaves")
    func registryCleanup() async {
        let pubsub = LocalPubSub()
        let streams = (0..<4).map { _ in pubsub.subscribe("ephemeral") }
        #expect(pubsub.subscriberCount(for: "ephemeral") == 4)
        #expect(pubsub.activeTopicCount == 1)

        for stream in streams {
            let consumer = Task { for await _ in stream {} }
            consumer.cancel()
            await consumer.value
        }
        #expect(pubsub.subscriberCount(for: "ephemeral") == 0)
        #expect(pubsub.activeTopicCount == 0)
    }

    // MARK: - Concurrency

    @Test("concurrent publishers and subscribers: complete delivery, per-publisher order")
    func concurrentStress() async {
        let pubsub = LocalPubSub()
        let publisherCount = 8
        let messagesPerPublisher = 250
        let subscriberCount = 4
        let total = publisherCount * messagesPerPublisher

        let results = await withTaskGroup(of: [Int: [Int]]?.self) { group in
            // Register everyone before the first publisher task is added —
            // subscribe is synchronous, so all subscribers observe every
            // message published below. Each stream is held only by its
            // consuming task, so ending the task releases the subscription.
            for _ in 0..<subscriberCount {
                let stream = pubsub.subscribe("stress")
                group.addTask {
                    var sequencesByPublisher: [Int: [Int]] = [:]
                    var received = 0
                    for await message in stream {
                        let publisher = Int(message.metadata["publisher"]!)!
                        let sequence = Int(message.metadata["seq"]!)!
                        sequencesByPublisher[publisher, default: []].append(sequence)
                        received += 1
                        if received == total { break }
                    }
                    return sequencesByPublisher
                }
            }
            for publisher in 0..<publisherCount {
                group.addTask {
                    for sequence in 0..<messagesPerPublisher {
                        await pubsub.publish(
                            msg("stress", "m", metadata: ["publisher": "\(publisher)", "seq": "\(sequence)"])
                        )
                    }
                    return nil
                }
            }
            var collected: [[Int: [Int]]] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        #expect(results.count == subscriberCount)
        for sequencesByPublisher in results {
            var receivedTotal = 0
            for publisher in 0..<publisherCount {
                let sequences = sequencesByPublisher[publisher] ?? []
                receivedTotal += sequences.count
                // Sequential publishes from one task arrive in publish order.
                #expect(sequences == Array(0..<messagesPerPublisher))
            }
            #expect(receivedTotal == total)
        }
        #expect(await eventually { pubsub.subscriberCount(for: "stress") == 0 })
    }

    @Test("subscribe/unsubscribe churn during publishing neither crashes nor corrupts")
    func churn() async {
        let pubsub = LocalPubSub()
        var anchor = pubsub.subscribe("churn").makeAsyncIterator()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<500 {
                    await pubsub.publish(msg("churn", "\(i)"))
                }
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<50 {
                        let stream = pubsub.subscribe("churn")
                        let consumer = Task { for await _ in stream {} }
                        consumer.cancel()
                        await consumer.value
                    }
                }
            }
        }

        // The anchor subscriber saw every one of the 500, in order.
        for i in 0..<500 {
            let received = await anchor.next()
            #expect(received.map(text) == "\(i)")
        }
        #expect(await eventually { pubsub.subscriberCount(for: "churn") == 1 })
    }

    @Test("two independent subscriptions from one task are independent streams")
    func independentStreams() async {
        let pubsub = LocalPubSub()
        var first = pubsub.subscribe("dual").makeAsyncIterator()
        var second = pubsub.subscribe("dual").makeAsyncIterator()
        await pubsub.publish(msg("dual", "both"))
        let receivedFirst = await first.next()
        let receivedSecond = await second.next()
        #expect(receivedFirst.map(text) == "both")
        #expect(receivedSecond.map(text) == "both")
    }
}
