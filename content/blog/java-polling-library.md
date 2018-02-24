+++
date = "2018-02-24T17:12:00+08:00"
title = "如何用最少的代码写一个健壮的轮询"
categories = ["技术"]
+++

工作中，是否时不时地会需要写一段轮询的逻辑？我在工作中还是经常遇到的，随便列举一下就有：

- 等待一个异步任务执行完成
- 定期获取系统状态
- 请求API，在遇到错误时重试

轮询本身的逻辑说难也不难，大部分时候或许我们甩开膀子临时撸一段代码就搞定了。但是轮询逻辑如果要写得健壮，却又不是那么简单，有很多需要考虑的方面，包括异常处理，等待策略，终止条件等等。

不信？就拿这次春晚闹得沸沸扬扬的「淘宝崩溃事件」作为例子吧。据[手淘的春晚项目负责人说](https://www.zhihu.com/question/267190744/answer/324193411)，事故原因是因为用户几乎同一时刻登录手淘，流量过大触发限流导致的。流量过大的一部分原因，是由于**客户端在请求失败时反复重试，进一步放大了流量**。如果客户端在重试前等待随机秒数，或是等待时间随失败次数增加而延长，虽然未必能够避免流量拥堵，但一定程度上是可以分散流量，减少被限流的可能性。换言之，这个登录请求就是一个不够健壮的轮询操作。

当然，手淘的登录流程一定是非常复杂的，不可能是一个简单的轮询。不过这里简化一下，假设登录流程仅仅是对一个API的调用。如果要让这个轮询变得健壮，那么需要满足以下要求

1. 至多请求5次，如果5次都不成功，则不再重试。向用户提示错误，等待用户手动重试。
2. 遇到用户错误（例如密码错误）时，向用户提示，不再重试。
3. 遇到技术错误时，等待一定时间后重试。
4. 为了分散对服务器的负荷，等待时间随失败次数不断延长，假设是指数级增长。
5. 需要处理等待过程中线程被打断等情况。

以上这些需求，用代码实现需要多少行呢？30行？50行？100行？

答案是：

<strong><span style="font-size: 24px;">16行</span></strong>

不骗你，以下就是代码

```java
public Long login() throws ExecutionException, InterruptedException {
    Poller<Long> poller = PollerBuilder.<String>newBuilder()
            .polling(() -> {
                Response resp = doLoginRequest();
                // 登录成功
                if (resp.isSuccess()) {
                    return AttemptResults.finishWith(resp.getUsrId());
                // 登录失败（假设原因是用户名/密码错误）
                } else {
                    return AttemptResults.breakFor("Unauthenticated");
                }
            })
            .withWaitStrategy(WaitStrategies.exponentialWait(1000, 16, TimeUnit.SECONDS)) // 等待时间指数级增加，初始为1秒，最大16秒
            .withStopStrategy(StopStrategies.stopAfterAttempt(5)) // 至多重试5次
            .build();

    return poller.start().get();
}
```

之所以代码可以这么简单，是因为用到了一个我最近开发的库：**polling**。对的，其实这是一篇广告 :)

# 使用 polling

polling 的项目地址在

[https://github.com/dyng/polling](https://github.com/dyng/polling)

因为 polling 已经发布到 maven 中央库，所以安装 polling 只需要像正常的 maven 依赖一样，加入 pom 文件即可。

```xml
<dependency>
    <groupId>com.dyngr</groupId>
    <artifactId>polling</artifactId>
    <version>1.1.1</version>
</dependency>
```

接下来说明如何创建一段轮询逻辑。

## 创建 poller

创建 poller 主要分为三部分

- 轮询逻辑，就是业务逻辑啦。
- 等待策略，决定两次请求间的等待时长。
- 终止策略，决定是否需要终止轮询。

API 比较直观，我想看过下面这段代码就一目了然了。

```java
Poller<Long> poller = PollerBuilder.<Long>newBuilder()
        .polling(() -> {
            // 业务逻辑
        })
        .withStopStrategy(...) // 终止策略
        .withWaitStrategy(...) // 等待策略
        .build();
```

### 轮询逻辑

轮询逻辑就是你的业务逻辑，需要实现`AttemptMaker`接口，不过大部分情况下只要使用lambda表达式就无需意识到接口的形式。典型的轮询逻辑类似这样

```java
Poller<Long> poller = PollerBuilder.<Long>newBuilder()
        .polling(() -> {
            Response resp = requestTaskStatus(); // 查询提交的任务的状态
            if (resp.isDone()) {
                // 任务运行结束，返回任务结果
                return AttemptResults.finishWith(resp.getResult());
            } else {
                // 任务运行还未结束，继续轮询
                return AttemptResults.justContinue();
            }
        })
        .build();
```

唯一需要注意的是返回值，类型是`AttemptResult`，推荐使用 polling 提供的工厂类`AttemptResults`来构建。`AttempResults`有三个方法，分别代表了三种含义：

**finishWith**

表示已经取得期望的结果，返回这个结果并结束轮询。
	
**justContinue**

表示没有取得期望的结果，继续轮询。

**breakFor**

表示出现了预期以外的情况，需要终止轮询。

### 等待策略

等待策略决定了两次重试之间的等待时间。polling 库内置了很多常用的等待策略，例如

- 固定等待
- 随机等待
- 指数增长等待
- 斐波那契增长等待

所有策略可以在`WaitStrategies`类里找到。当然，可能所有这些内置的策略都没法满足你的业务场景，你也可以自定义等待策略，只需要实现`WaitStrategy`接口就可以了

```java
public interface WaitStrategy {
    /**
     * Returns the time, in milliseconds, to sleep before retrying.
     *
     * @param failedAttempt the previous failed {@code Attempt}
     * @return the sleep time before next attempt
     */
    long computeWaitTime(Attempt failedAttempt);
}
```

### 终止策略

终止策略决定了在哪些条件下轮询需要强制退出。polling 库内置的终止策略有以下这些

- 重试达到一定次数后终止
- 重试总耗时达到一定时间后终止

和等待策略类似，你也可以自定义终止策略。终止策略的接口如下

```java
public interface StopStrategy {
    /**
     * Returns <code>true</code> if the retryer should stop retrying.
     *
     * @param failedAttempt the previous failed {@code Attempt}
     * @return <code>true</code> if the retryer must stop, <code>false</code> otherwise
     */
    boolean shouldStop(Attempt failedAttempt);
}
```

最后再介绍一些 polling 的常用功能吧。

### 1. 多个终止条件

轮询的终止条件有时候可能会有很多个，例如

1. 轮询次数达到100次
2. 轮询总耗时达到1小时

当以上任何一个条件满足时，就结束轮询。要实现这一点其实也很简单，在构建 poller 时只需要给出多个终止条件，polling 就会自动地把这些条件组合起来。

示例代码如下

```java
Poller<Long> poller = PollerBuilder.<Long>newBuilder()
        ...
        .withStopStrategy(
            StopStrategies.stopAfterAttempt(100),
            StopStrategies.stopAfterDelay(1, TimeUnit.HOURS)
        )
        ...
        .build();
```

### 2. 异步轮询

polling 除了支持在当前线程轮询以外，也支持在给定的线程池进行异步轮询。

使用方法很简单，只需要在构建 poller 时通过 `withExecutorService` 方法指定线程池即可。

```java
Poller<Long> poller = PollerBuilder.<Long>newBuilder()
        ...
        .withExecutorService(Executors.newSingleThreadExecutor())
        ...
        .build();

// 得到返回值的Future
Future<Long> future = poller.start();
```

### 3. 错误处理

有时候 polling 会失败并且终止，这时你很可能会想知道导致失败的原因。polling 通过`ExecutionException`来传递错误原因。

失败的原因一般有以下几种

- 主动退出
- 满足指定的终止条件（到达最大错误次数，到达最长等待时间等）
- 未捕获异常
- 线程在等待时被打断

以判断是否是*主动退出*为例，示例代码如下

```java
try {
    poller.start().get();
} catch (ExecutionException e) {
    if (e.getCause() instanceof UserBreakException) {
        logger.info("This is an user break");
    } else {
        logger.info("This is NOT an user break");
    }
}
```

polling 目前有三个 Exception 类用于表示错误原因，分别是

**UserBreakException**

- 主动退出

**PollerStoppedException**

- 满足指定的终止条件（到达最大错误次数，到达最长等待时间等）
- 未捕获异常

**PollerInterruptedException**

- 线程在等待时被打断

## 写在最后

写 polling 库是因为最近在读老项目的代码，发现轮询的代码散落各处，重复劳动很多，而且还不太健壮。特别是新功能也需要使用轮询，于是就想把这些代码统一起来。目前代码还有不少不成熟的地方（例如错误处理就显得有些复杂），大家在使用过程中如有什么问题，或是有需求无法实现，可以在 github 上新建 issue，我会抽时间尽力完善。
