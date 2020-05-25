const AWS = require("aws-sdk");
const autoscaling = new AWS.AutoScaling({apiVersion: '2011-01-01'});

exports.handler = (event, context) => {
  const asg_name = event.asg_name;
  const cmd = event.cmd;
  var desired_count = event.count;

  var params = {
    AutoScalingGroupNames: [asg_name]
  };

  autoscaling.describeAutoScalingGroups(params, function (err, data) {
    var asg_info = data.AutoScalingGroups[0];
    if (err) console.log("Fail to load Autoscaling Group info :", err, err.stack); // an error occurred
    else {
      console.log("data :", asg_info);
      const max_size = asg_info.MaxSize;
      const min_size = asg_info.MinSize;

      if (cmd == "add") {
        var running_count = asg_info.DesiredCapacity;
        desired_count += running_count;
      }

      if (desired_count > max_size) {
        desired_count = max_size;
      } else if (desired_count < min_size) {
        desired_count = min_size;
      }

      console.log("AutoScaling Group Name : ", asg_name);
      console.log("Desired Count :", desired_count);
      console.log("Min : ", min_size, " Max : ", max_size);

      params = {
        AutoScalingGroupName: asg_name,
        DesiredCapacity: desired_count
      };

      autoscaling.setDesiredCapacity(params, function (err, data) {
        if (err) {
          console.log("Fail To Set Desired Capacity :", err, err.stack); // an error occurred
        } else {
          console.log(data);
        }
      });
    }
  });
};
