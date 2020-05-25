const AWS = require("aws-sdk");
const ecs = new AWS.ECS({apiVersion: '2014-11-13'});

exports.handler = (event, context) => {
  const cluster_name = event.cluster;
  const service_name = event.service;
  var desired_count = event.count;
  var cmd = event.cmd;

  var params = {
    cluster: cluster_name,
    services: [service_name],
  };

  ecs.describeServices(params, function (err, data) {
    if (err) {
      console.log('error:', "Fail to Load Service" + err);
    } else {
      var service = data.services[0];
      if (service == undefined) {
        console.log('error:', "Fail to Find Service");
      } else {
        console.log("data : " + JSON.stringify(service)); // successful response
        if (cmd == "add") {
          var running_count = service.runningCount;
          desired_count += running_count;
        }

        console.log("Cluster : " + cluster_name);
        console.log("Service : " + service_name);
        console.log("Count : " + desired_count);
        console.log("Command : " + cmd);

        params = {
          cluster: cluster_name,
          service: service_name,
          desiredCount: desired_count
        };

        console.log(params);

        ecs.updateService(params, function (err, data) {
          if (err) {
            console.log("Error : Fail to update Service ", err, err.stack);
          } else console.log(data);
        });
      }
    }
  });
};
