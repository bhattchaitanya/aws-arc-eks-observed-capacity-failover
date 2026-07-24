import {
  constantUsersPerSec,
  getParameter,
  rampUsersPerSec,
  scenario,
  simulation,
} from "@gatling.io/core";
import { http, status } from "@gatling.io/http";

export default simulation((setUp) => {
  const target = getParameter("target", "http://localhost:8080");
  const usersPerSecond = Number(getParameter("rate", "1000"));
  const durationSeconds = Number(getParameter("duration", "60"));
  const rampSeconds = Number(getParameter("ramp", "15"));

  const httpProtocol = http
    .baseUrl(target)
    .acceptHeader("application/json")
    .userAgentHeader("arc-eks-observed-capacity-gatling/1.0")
    // Model a service client with a long-lived shared connection pool. Without
    // this, one-shot virtual users create a new pool each and measure the load
    // generator's file-descriptor ceiling instead of destination capacity.
    .shareConnections();

  const readTransaction = scenario("Read a transaction").exec(
    http("GET transaction")
      .get("/")
      .check(status().is(200)),
  );

  const injectionSteps = rampSeconds > 0
    ? [
        rampUsersPerSec(Math.min(100, usersPerSecond))
          .to(usersPerSecond)
          .during(rampSeconds),
        constantUsersPerSec(usersPerSecond).during(durationSeconds),
      ]
    : [constantUsersPerSec(usersPerSecond).during(durationSeconds)];

  setUp(readTransaction.injectOpen(...injectionSteps)).protocols(httpProtocol);
});
